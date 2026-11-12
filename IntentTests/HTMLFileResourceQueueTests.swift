import Foundation
@testable import Intent
import Testing
import UIKit
import WebKit

/// Loads that find the page budget reserved by loads in flight wait their turn instead of failing.
@MainActor
struct HTMLFileResourceQueueTests {
    private typealias Policy = HTMLFileResourcePolicy
    private typealias FetchGate = HTMLFileResourceTestSupport.FetchGate
    private typealias RecordingSchemeTask = HTMLFileResourceTestSupport.RecordingSchemeTask

    private func load(_ reference: String, with handler: HTMLFileResourceHandler, base: URL) async -> Result<Data, Policy.Rejection> {
        await HTMLFileResourceTestSupport.load(reference, with: handler, base: base)
    }

    private func paddedPNG(byteCount: Int) -> Data { HTMLFileResourceTestSupport.paddedPNG(byteCount: byteCount) }

    private func settle(until condition: () -> Bool) async { await HTMLFileResourceTestSupport.settle(until: condition) }

    @Test func tenConcurrentSmallAssetsAllLoad() async throws {
        let gate = FetchGate()
        let png = paddedPNG(byteCount: 0)
        let handler = HTMLFileResourceHandler(workspaceId: "ws-a") { _, _, _ in
            await gate.wait()
            return png
        }
        let base = try #require(handler.beginPage(filePath: "reports/index.html"))
        let urls = try (0..<10).map { try #require(URL(string: "image-\($0).png", relativeTo: base)?.absoluteURL) }
        let loads = urls.map { url in Task { await handler.load(url).map(\.1) } }
        let admitted = Policy.maxPageBytes / Policy.maxResourceBytes
        await settle { gate.waiting == admitted }
        for _ in 0..<100 { await Task.yield() }
        #expect(gate.waiting == admitted, "The rest wait for room instead of failing")
        gate.release()
        for load in loads {
            #expect(await load.value == .success(png))
        }
    }

    @Test func concurrentLargeAssetsNeverExceedThePageCapInFlight() async throws {
        let gate = FetchGate()
        let size = Policy.maxResourceBytes * 3 / 4
        var inFlight = 0
        var peak = 0
        let handler = HTMLFileResourceHandler(workspaceId: "ws-a") { _, _, limit in
            inFlight += limit
            peak = max(peak, inFlight)
            defer { inFlight -= limit }
            await gate.wait()
            guard size <= limit else { throw WorkspaceFileImageLoader.LoadError.fileTooLarge }
            return paddedPNG(byteCount: size)
        }
        let base = try #require(handler.beginPage(filePath: "index.html"))
        let url = try #require(URL(string: "large.png", relativeTo: base)?.absoluteURL)
        let loads = (0..<8).map { _ in Task { await handler.load(url).map(\.1.count) } }
        await settle { gate.waiting == Policy.maxPageBytes / Policy.maxResourceBytes }
        gate.release()
        var results: [Result<Int, Policy.Rejection>] = []
        for load in loads { results.append(await load.value) }

        #expect(peak <= Policy.maxPageBytes, "Reserved in flight: \(peak)")
        let served = results.compactMap { try? $0.get() }
        #expect(served.reduce(0, +) <= Policy.maxPageBytes)
        #expect(served.count == Policy.maxPageBytes / size, "\(results)")
        #expect(!results.contains(.failure(.cancelled)))
    }

    @Test func stoppingAQueuedRequestMakesNoCallbacksAndSkipsItsFetch() async throws {
        let gate = FetchGate()
        var fetched: [String] = []
        let handler = HTMLFileResourceHandler(workspaceId: "ws-a") { _, path, limit in
            fetched.append(path)
            await gate.wait()
            return paddedPNG(byteCount: min(limit, 1024))
        }
        let base = try #require(handler.beginPage(filePath: "index.html"))
        let webView = WKWebView()
        let admitted = Policy.maxPageBytes / Policy.maxResourceBytes
        let running = try (0..<admitted).map { RecordingSchemeTask(url: try #require(URL(string: "run-\($0).png", relativeTo: base)?.absoluteURL)) }
        let queued = RecordingSchemeTask(url: try #require(URL(string: "queued.png", relativeTo: base)?.absoluteURL))
        let next = RecordingSchemeTask(url: try #require(URL(string: "next.png", relativeTo: base)?.absoluteURL))
        running.forEach { handler.webView(webView, start: $0) }
        handler.webView(webView, start: queued)
        handler.webView(webView, start: next)
        await settle { gate.waiting == admitted }
        handler.webView(webView, stop: queued)
        for _ in 0..<100 { await Task.yield() }
        gate.release()
        await settle { (running + [next]).allSatisfy { $0.callbacks.count == 3 } }
        for _ in 0..<100 { await Task.yield() }

        #expect((running + [next]).allSatisfy { $0.callbacks == ["response", "data", "finish"] })
        #expect(queued.callbacks.isEmpty, "\(queued.callbacks)")
        #expect(!fetched.contains("queued.png"), "A stopped request leaves the queue before fetching")
        #expect(fetched.contains("next.png"))
    }

    @Test func beginPageClearsTheQueue() async throws {
        let gate = FetchGate()
        var fetched: [String] = []
        let handler = HTMLFileResourceHandler(workspaceId: "ws-a") { _, path, limit in
            fetched.append(path)
            if path.hasPrefix("old") { await gate.wait() }
            return paddedPNG(byteCount: min(limit, 1024))
        }
        let oldBase = try #require(handler.beginPage(filePath: "index.html"))
        let webView = WKWebView()
        let admitted = Policy.maxPageBytes / Policy.maxResourceBytes
        let running = try (0..<admitted).map { RecordingSchemeTask(url: try #require(URL(string: "old-\($0).png", relativeTo: oldBase)?.absoluteURL)) }
        running.forEach { handler.webView(webView, start: $0) }
        let queuedURL = try #require(URL(string: "old-queued.png", relativeTo: oldBase)?.absoluteURL)
        let queued = (0..<2).map { _ in Task { await handler.load(queuedURL).map(\.1) } }
        await settle { gate.waiting == admitted }

        let newBase = try #require(handler.beginPage(filePath: "index.html"))
        for load in queued {
            #expect(await load.value == .failure(.cancelled), "Queued loads end without waiting for the old page")
        }
        let fresh = await load("new.png", with: handler, base: newBase)
        #expect(fresh.map(\.count) == .success(1024), "\(fresh.map(\.count))")
        gate.release()
        for _ in 0..<100 { await Task.yield() }
        #expect(running.allSatisfy { $0.callbacks.isEmpty })
        #expect(!fetched.contains("old-queued.png"))
    }
}
