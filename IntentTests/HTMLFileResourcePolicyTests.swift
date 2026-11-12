import Foundation
@testable import Intent
import Testing
import UIKit
import WebKit

@MainActor
struct HTMLFileResourcePolicyTests {
    private typealias Policy = HTMLFileResourcePolicy

    private static let host = "page-token"

    private func base(_ filePath: String = "reports/Demo report.html") throws -> URL {
        try #require(Policy.baseURL(host: Self.host, filePath: filePath))
    }

    private func resolve(_ reference: String, from filePath: String = "reports/Demo report.html") throws -> Policy.Resource {
        let url = try #require(URL(string: reference, relativeTo: try base(filePath))?.absoluteURL)
        return try Policy.resource(for: url, host: Self.host)
    }

    private func rejection(_ reference: String, from filePath: String = "reports/Demo report.html") throws -> Policy.Rejection? {
        do {
            _ = try resolve(reference, from: filePath)
            return nil
        } catch let error as Policy.Rejection {
            return error
        }
    }

    @Test func baseURLPlacesTheReportUnderThePerPageWorkspaceRoot() throws {
        let url = try base()
        #expect(url.scheme == "intent-file")
        #expect(url.host() == Self.host)
        #expect(url.path(percentEncoded: true) == "/workspace/reports/Demo%20report.html")
        #expect(try base("./reports/./a.html").path(percentEncoded: true) == "/workspace/reports/a.html")
        #expect(Policy.baseURL(host: Self.host, filePath: "../a.html") == nil)
        #expect(Policy.baseURL(host: Self.host, filePath: "reports/../../a.html") == nil)
        #expect(Policy.baseURL(host: Self.host, filePath: "") == nil)
    }

    @Test func resolvesRelativeAndNestedReferencesInsideTheWorkspace() throws {
        #expect(try resolve("images/chart.png") == Policy.Resource(path: "reports/images/chart.png", kind: .image(mimeType: "image/png")))
        #expect(try resolve("./assets/deep/nested/report.css") == Policy.Resource(path: "reports/assets/deep/nested/report.css", kind: .stylesheet))
        #expect(try resolve("../shared/logo.JPG").path == "shared/logo.JPG")
        #expect(try resolve("Chart%20One.webp?v=2#top").path == "reports/Chart One.webp")
        #expect(try resolve("photo.jpeg").kind == .image(mimeType: "image/jpeg"))
        #expect(try resolve("loop.gif").kind == .image(mimeType: "image/gif"))
        #expect(try resolve("top.png", from: "index.html").path == "top.png")
    }

    @Test func rejectsEscapesAbsolutePathsAndOtherOrigins() throws {
        #expect(try rejection("../../secret.png") == .outsideWorkspace)
        #expect(try rejection("../../../../etc/passwd.png") == .outsideWorkspace)
        #expect(try rejection("/etc/secret.png") == .outsideWorkspace)
        #expect(try rejection("%2e%2e/%2e%2e/secret.png") == .outsideWorkspace)
        #expect(try rejection("images/..%2F..%2F..%2Fsecret.png") == .outsideWorkspace)
        #expect(try rejection("a%5C..%5Csecret.png") == .outsideWorkspace)
        #expect(try rejection("images%2Fchart.png") == .outsideWorkspace, "An encoded separator never splits a name")
        #expect(try rejection("bad%00name.png") == .outsideWorkspace)
        #expect(try rejection("images//chart.png") == .outsideWorkspace)
        #expect(try rejection("intent-file://other-page/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("intent-file://user@\(Self.host)/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("intent-file://\(Self.host):8080/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("https://\(Self.host)/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("file:///workspace/reports/chart.png") == .wrongOrigin)
    }

    @Test func rejectsTypesOtherThanImagesStylesheetsAndFonts() throws {
        for reference in ["page.html", "app.js", "logo.svg", "clip.mp4", "data.json", "README", "archive.png.zip"] {
            #expect(try rejection(reference) == .unsupportedType, "\(reference)")
        }
    }

    @Test func validatesContentAgainstTheDeclaredType() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        #expect(throws: Never.self) { try Policy.validate(png, as: .image(mimeType: "image/png")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("<html></html>".utf8), as: .image(mimeType: "image/png")) }
        #expect(throws: Never.self) { try Policy.validate(Data("h1 { color: red; }".utf8), as: .stylesheet) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data([0x68, 0x00, 0x31]), as: .stylesheet) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data([0xFF, 0xFE, 0xFD]), as: .stylesheet) }
    }

    @Test func allowsOnlyWebFontTypes() throws {
        #expect(try resolve("fonts/Report.woff2") == Policy.Resource(path: "reports/fonts/Report.woff2", kind: .font(mimeType: "font/woff2")))
        #expect(try resolve("fonts/Report.WOFF").kind == .font(mimeType: "font/woff"))
        #expect(try resolve("Report.ttf").kind == .font(mimeType: "font/ttf"))
        #expect(try resolve("Report.otf").kind == .font(mimeType: "font/otf"))
        for reference in ["Report.eot", "Report.ttc", "Report.dfont", "Report.fon", "Report.svgz", "Report.woff3"] {
            #expect(try rejection(reference) == .unsupportedType, "\(reference)")
        }
        #expect(try rejection("../../fonts/Report.woff2") == .outsideWorkspace)
    }

    @Test func validatesFontSignatures() throws {
        let inter = try Data(contentsOf: try #require(Bundle.main.url(forResource: "Inter-Regular", withExtension: "ttf")))
        #expect(throws: Never.self) { try Policy.validate(inter, as: .font(mimeType: "font/ttf")) }
        let accepted: [(String, [UInt8])] = [
            ("font/woff2", Array("wOF2".utf8)), ("font/woff", Array("wOFF".utf8)),
            ("font/ttf", Array("true".utf8)), ("font/otf", Array("OTTO".utf8))
        ]
        for (mimeType, signature) in accepted {
            let data = Data(signature + [0, 0, 0, 0])
            #expect(throws: Never.self, "\(mimeType)") { try Policy.validate(data, as: .font(mimeType: mimeType)) }
        }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(inter, as: .font(mimeType: "font/woff2")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("wOF".utf8), as: .font(mimeType: "font/woff2")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("<html>".utf8), as: .font(mimeType: "font/ttf")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("OTTO".utf8), as: .font(mimeType: "font/eot")) }
    }

    @Test func contentSecurityPolicyWidensOnlyImagesStylesAndFontsToTheScheme() {
        let directives = Policy.contentSecurityPolicy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(directives == [
            "default-src 'none'",
            "style-src 'unsafe-inline' intent-file:",
            "img-src data: intent-file:",
            "font-src intent-file:",
            "base-uri 'none'",
            "form-action 'none'"
        ])
    }

    @Test func webViewRegistersTheSchemeWithJavaScriptOff() async throws {
        let handler = HTMLFileResourceHandler(workspaceId: "ws") { _, _, _ in Data() }
        let coordinator = HTMLFileWebView.Coordinator(resources: handler) {}
        let webView = HTMLFileWebView.makeWebView(coordinator: coordinator, rules: try await HTMLFileWebView.blockingRules())
        defer { HTMLFileWebView.dismantleUIView(webView, coordinator: coordinator) }
        let registered = webView.configuration.urlSchemeHandler(forURLScheme: Policy.scheme) as? HTMLFileResourceHandler
        #expect(registered === handler)
        #expect(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(!webView.configuration.websiteDataStore.isPersistent)
    }

    // MARK: - Handler limits

    private func handler(serving files: [String: Data], fetched: ((String, Int) -> Void)? = nil) -> HTMLFileResourceHandler {
        HTMLFileResourceHandler(workspaceId: "ws-a") { workspaceId, path, limit in
            #expect(workspaceId == "ws-a")
            fetched?(path, limit)
            guard let data = files[path] else { throw URLError(.fileDoesNotExist) }
            guard data.count <= limit else { throw WorkspaceFileImageLoader.LoadError.fileTooLarge }
            return data
        }
    }

    private func load(_ reference: String, with handler: HTMLFileResourceHandler, base: URL) async -> Result<Data, Policy.Rejection> {
        let url = URL(string: reference, relativeTo: base)?.absoluteURL
        return await handler.load(url).map(\.1)
    }

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

    /// Holds fake fetches until the test releases them, so loads overlap deterministically.
    @MainActor
    private final class FetchGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        var waiting: Int { waiters.count }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// Records every callback WebKit would receive.
    private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        private(set) var callbacks: [String] = []

        init(url: URL) { request = URLRequest(url: url) }

        func didReceive(_: URLResponse) { callbacks.append("response") }
        func didReceive(_: Data) { callbacks.append("data") }
        func didFinish() { callbacks.append("finish") }
        func didFailWithError(_: any Error) { callbacks.append("fail") }
    }

    private func paddedPNG(byteCount: Int) -> Data {
        var png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        png.append(Data(count: max(0, byteCount - png.count)))
        return png
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
        }
    }

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
}
