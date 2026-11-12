import Foundation
@testable import Intent
import Testing
import UIKit
import WebKit

/// Per-resource and per-page limits, cancellation and absolute-path resolution in the report resource handler.
@MainActor
struct HTMLFileResourceHandlerTests {
    private typealias Policy = HTMLFileResourcePolicy
    private typealias FetchGate = HTMLFileResourceTestSupport.FetchGate
    private typealias RecordingSchemeTask = HTMLFileResourceTestSupport.RecordingSchemeTask

    private func handler(serving files: [String: Data], fetched: ((String, Int) -> Void)? = nil) -> HTMLFileResourceHandler {
        HTMLFileResourceTestSupport.handler(serving: files, fetched: fetched)
    }

    private func load(_ reference: String, with handler: HTMLFileResourceHandler, base: URL) async -> Result<Data, Policy.Rejection> {
        await HTMLFileResourceTestSupport.load(reference, with: handler, base: base)
    }

    private func paddedPNG(byteCount: Int) -> Data { HTMLFileResourceTestSupport.paddedPNG(byteCount: byteCount) }

    private func settle(until condition: () -> Bool) async { await HTMLFileResourceTestSupport.settle(until: condition) }

    // MARK: - Limits

    @Test func handlerServesTypedResponsesAndRejectsBeforeFetching() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        var fetched: [String] = []
        let handler = handler(serving: ["reports/chart.png": png, "reports/style.css": Data("p{}".utf8)]) { path, _ in fetched.append(path) }
        let base = try #require(handler.beginPage(filePath: "reports/index.html"))

        let image = try await handler.load(URL(string: "chart.png", relativeTo: base)?.absoluteURL).get()
        #expect(image.0.mimeType == "image/png")
        #expect(image.1 == png)
        let css = try await handler.load(URL(string: "style.css", relativeTo: base)?.absoluteURL).get()
        #expect(css.0.mimeType == "text/css")
        #expect(css.0.textEncodingName == "utf-8")

        #expect(await load("../../x.png", with: handler, base: base) == .failure(.outsideWorkspace))
        #expect(await load("app.js", with: handler, base: base) == .failure(.unsupportedType))
        #expect(await load("font.woff2", with: handler, base: base) == .failure(.invalidContent), "A missing font fails like a missing image")
        #expect(await load("missing.png", with: handler, base: base) == .failure(.invalidContent))
        #expect(fetched == ["reports/chart.png", "reports/style.css", "reports/font.woff2", "reports/missing.png"])
    }

    @Test func handlerEnforcesPerResourceAndPerPageCaps() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        var oversized = png
        oversized.append(Data(count: Policy.maxResourceBytes))
        var limits: [Int] = []
        let handler = handler(serving: ["big.png": oversized, "ok.png": png]) { _, limit in limits.append(limit) }
        let base = try #require(handler.beginPage(filePath: "index.html"))

        #expect(await load("big.png", with: handler, base: base) == .failure(.tooLarge))
        #expect(limits == [Policy.maxResourceBytes])
        for _ in 1..<Policy.maxPageRequests {
            #expect(await load("ok.png", with: handler, base: base) == .success(png))
        }
        #expect(await load("ok.png", with: handler, base: base) == .failure(.pageBudgetExhausted))
        #expect(limits.count == Policy.maxPageRequests, "The capped request never reaches the daemon")

        // A new page starts a fresh budget on a new base URL for the same per-view host.
        let next = try #require(handler.beginPage(filePath: "index.html"))
        #expect(await load("ok.png", with: handler, base: next) == .success(png))
    }

    @Test func handlerStopsServingOnceThePageByteBudgetIsSpent() async throws {
        let chunk = Policy.maxResourceBytes
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        var large = png
        large.append(Data(count: chunk - png.count))
        var limits: [Int] = []
        let handler = handler(serving: ["a.png": large]) { _, limit in limits.append(limit) }
        let base = try #require(handler.beginPage(filePath: "index.html"))
        let fullLoads = Policy.maxPageBytes / chunk
        for _ in 0..<fullLoads {
            #expect(await load("a.png", with: handler, base: base) == .success(large))
        }
        #expect(await load("a.png", with: handler, base: base) == .failure(.pageBudgetExhausted))
        #expect(limits == Array(repeating: chunk, count: fullLoads))
    }

    // MARK: - Concurrency and cancellation

    @Test func concurrentLoadsReserveThePageBudgetBeforeFetching() async throws {
        let gate = FetchGate()
        var limits: [Int] = []
        let handler = HTMLFileResourceHandler(workspaceId: "ws-a") { _, _, limit in
            limits.append(limit)
            await gate.wait()
            return paddedPNG(byteCount: limit)
        }
        let base = try #require(handler.beginPage(filePath: "index.html"))
        let url = try #require(URL(string: "chart.png", relativeTo: base)?.absoluteURL)
        let attempts = Policy.maxPageBytes / Policy.maxResourceBytes * 2
        let loads = (0..<attempts).map { _ in Task { await handler.load(url).map(\.1.count) } }
        await settle { gate.waiting == attempts / 2 }
        for _ in 0..<attempts { await Task.yield() }
        #expect(gate.waiting == attempts / 2, "Loads past the reserved cap never start a fetch")
        gate.release()
        var results: [Result<Int, Policy.Rejection>] = []
        for load in loads { results.append(await load.value) }

        let reserved = limits.reduce(0, +)
        #expect(reserved <= Policy.maxPageBytes, "\(limits)")
        let served = results.compactMap { try? $0.get() }
        let servedTotal = served.reduce(0, +)
        #expect(servedTotal <= Policy.maxPageBytes)
        #expect(served.count == attempts / 2)
        #expect(results.filter { $0 == .failure(.pageBudgetExhausted) }.count == attempts / 2)
    }

    @Test func releasesUnusedReservationsWhenLoadsFinishOrFail() async throws {
        let small = paddedPNG(byteCount: 0)
        var limits: [Int] = []
        let handler = handler(serving: ["small.png": small]) { _, limit in limits.append(limit) }
        let base = try #require(handler.beginPage(filePath: "index.html"))
        #expect(await load("missing.png", with: handler, base: base) == .failure(.invalidContent))
        #expect(await load("small.png", with: handler, base: base) == .success(small))
        #expect(await load("small.png", with: handler, base: base) == .success(small))
        #expect(limits == [
            Policy.maxResourceBytes, Policy.maxResourceBytes, Policy.maxResourceBytes
        ], "A finished or failed load keeps only its delivered bytes")
    }

    @Test func stoppedTaskReceivesNoCallbacksWhenItsFetchResolvesLater() async throws {
        let gate = FetchGate()
        let png = paddedPNG(byteCount: 0)
        let handler = HTMLFileResourceHandler(workspaceId: "ws-a") { _, _, _ in
            await gate.wait()
            return png
        }
        let base = try #require(handler.beginPage(filePath: "index.html"))
        let url = try #require(URL(string: "chart.png", relativeTo: base)?.absoluteURL)
        let webView = WKWebView()
        let stopped = RecordingSchemeTask(url: url)
        let control = RecordingSchemeTask(url: url)
        handler.webView(webView, start: stopped)
        handler.webView(webView, start: control)
        await settle { gate.waiting == 2 }
        #expect(gate.waiting == 2)
        handler.webView(webView, stop: stopped)
        gate.release()
        await settle { control.callbacks.count == 3 }
        #expect(control.callbacks == ["response", "data", "finish"])
        for _ in 0..<100 { await Task.yield() }
        #expect(stopped.callbacks.isEmpty, "\(stopped.callbacks)")
    }

    @Test func beginPageCancelsThePreviousPageAndResetsItsBudget() async throws {
        let gate = FetchGate()
        var limits: [Int] = []
        let handler = HTMLFileResourceHandler(workspaceId: "ws-a") { _, path, limit in
            limits.append(limit)
            if path == "old.png" { await gate.wait() }
            return paddedPNG(byteCount: limit)
        }
        let oldBase = try #require(handler.beginPage(filePath: "index.html"))
        let oldURL = try #require(URL(string: "old.png", relativeTo: oldBase)?.absoluteURL)
        let webView = WKWebView()
        let oldTasks = (0..<(Policy.maxPageBytes / Policy.maxResourceBytes)).map { _ in RecordingSchemeTask(url: oldURL) }
        oldTasks.forEach { handler.webView(webView, start: $0) }
        await settle { gate.waiting == oldTasks.count }
        #expect(gate.waiting == oldTasks.count, "The old page holds the whole byte budget")

        let newBase = try #require(handler.beginPage(filePath: "index.html"))
        gate.release()
        for _ in 0..<100 { await Task.yield() }
        let delivered = oldTasks.flatMap(\.callbacks)
        #expect(delivered.isEmpty, "Cancelled loads from the old page never deliver: \(delivered)")

        for _ in 0..<(Policy.maxPageBytes / Policy.maxResourceBytes) {
            let result = await load("new.png", with: handler, base: newBase)
            #expect(result.map(\.count) == .success(Policy.maxResourceBytes))
        }
        #expect(Array(limits.suffix(oldTasks.count)) == Array(repeating: Policy.maxResourceBytes, count: oldTasks.count))
    }

    @Test func handlerSendsAnAbsoluteReportsAssetsAsAbsolutePaths() async throws {
        let png = paddedPNG(byteCount: 0)
        var fetched: [String] = []
        let handler = handler(serving: ["/Users/alice/project/reports/chart.png": png, "reports/chart.png": png]) { path, _ in
            fetched.append(path)
        }
        let absolute = try #require(handler.beginPage(filePath: "/Users/alice/project/reports/report.html"))
        #expect(await load("chart.png", with: handler, base: absolute) == .success(png))
        #expect(await load("../../../../../../x.png", with: handler, base: absolute) == .failure(.outsideWorkspace))

        // The next page is workspace-relative again, and the absolute page's URLs no longer resolve.
        let relative = try #require(handler.beginPage(filePath: "reports/report.html"))
        #expect(await load("chart.png", with: handler, base: relative) == .success(png))
        #expect(await load("chart.png", with: handler, base: absolute) == .failure(.outsideWorkspace))
        #expect(fetched == ["/Users/alice/project/reports/chart.png", "reports/chart.png"])
    }
}
