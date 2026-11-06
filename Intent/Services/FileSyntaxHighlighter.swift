import Foundation
import WebKit

@MainActor
final class FileSyntaxHighlighter: NSObject, WKNavigationDelegate {
    static let shared = FileSyntaxHighlighter()
    static let maxBytes = 512 * 1024 // swiftlint:disable:this no_magic_numbers
    private static let timeoutSeconds = 5
    private static let pollMilliseconds = 20
    private static let timeout: Duration = .seconds(timeoutSeconds)
    private static let pollInterval: Duration = .milliseconds(pollMilliseconds)

    static var pageURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Highlights")
    }

    private struct Request {
        let continuation: CheckedContinuation<[FileSyntaxRun], Never>
        let work: Task<Void, Never>
        let timeout: Task<Void, Never>
    }

    private var webView: WKWebView?
    private var ready = false
    private var requests: [UUID: Request] = [:]

    func highlight(source: String, path: String, dark: Bool) async -> [FileSyntaxRun] {
        guard !Task.isCancelled, source.utf8.count <= Self.maxBytes, Self.pageURL != nil else { return [] }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: [])
                    return
                }
                startIfNeeded()
                let work = Task<Void, Never> { [weak self] in
                    await self?.render(id: id, source: source, path: path, dark: dark)
                }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: Self.timeout) } catch { return }
                    self?.reset()
                }
                requests[id] = Request(continuation: continuation, work: work, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, runs: []) }
        }
    }

    private func startIfNeeded() {
        guard webView == nil, let url = Self.pageURL else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func render(id: UUID, source: String, path: String, dark: Bool) async {
        do {
            while !ready {
                try Task.checkCancellation()
                try await Task.sleep(for: Self.pollInterval)
            }
            try Task.checkCancellation()
            guard let webView else { return }
            let result = try await webView.callPageJavaScript(
                "return JSON.stringify(await window.intentHighlights.highlight(request));",
                arguments: ["request": ["source": source, "path": path, "dark": dark]]
            )
            // Decoding a large file's runs takes tens of milliseconds; keep it off the main thread.
            let runs = await Task.detached(priority: .userInitiated) {
                result.map { FileSyntaxRun.decode($0, source: source) } ?? []
            }.value
            finish(id: id, runs: runs)
        } catch {
            finish(id: id, runs: [])
        }
    }

    private func finish(id: UUID, runs: [FileSyntaxRun]) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.work.cancel()
        request.timeout.cancel()
        request.continuation.resume(returning: runs)
    }

    private func reset() {
        ready = false
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        for id in Array(requests.keys) { finish(id: id, runs: []) }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        guard webView === self.webView else { return }
        ready = true
    }

    // swiftlint:disable:next async_without_await
    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == Self.pageURL
            ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation?, withError _: any Error) {
        if webView === self.webView { reset() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError _: any Error) {
        if webView === self.webView { reset() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { reset() }
    }
}
