import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class WorkspaceBrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    /// The main-frame load. A failure replaces the page until the next load or Reload.
    private(set) var loadPhase = LoadPhase.idle
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var isLoading: Bool { loadPhase.isLoading }
    var errorMessage: String? { loadPhase.anyFailureMessage }
    private(set) var address = ""
    private(set) var title = ""
    @ObservationIgnored private var titleObserver: NSKeyValueObservation?
    @ObservationIgnored private var proxy: (any BrowserProxySession)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var originalOrigins: [String: URLComponents] = [:]

    func open(_ browser: WorkspaceBrowser, connection: any SessionConnectionManaging) async {
        stop()
        let generation = generation
        loadPhase = .loading(lastLoadedAt: nil)
        do {
            guard let url = URL(string: browser.url) else { throw URLError(.badURL) }
            let proxy = try await connection.makeBrowserProxy()
            guard self.generation == generation, !Task.isCancelled else {
                await proxy.close()
                return
            }
            self.proxy = proxy
            let forwarded = try await proxy.forward(url)
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            rememberOrigin(url, forwarded: forwarded)
            address = browser.url
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = true
            self.webView = webView
            observeTitle(webView)
            webView.load(URLRequest(url: forwarded))
        } catch {
            guard self.generation == generation else { return }
            stop()
            if !(error is CancellationError) { fail(error.localizedDescription) }
        }
    }

    func stop() {
        generation = UUID()
        titleObserver = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        canGoBack = false
        canGoForward = false
        loadPhase = .idle
        address = ""
        title = ""
        originalOrigins.removeAll()
        if let proxy {
            self.proxy = nil
            Task { await proxy.close() }
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func navigate(to input: String) async throws {
        let normalized = try WorkspaceBrowserURL.normalize(input)
        guard let url = URL(string: normalized), let proxy, let webView else { throw BrowserTunnelError.closed }
        generation = UUID()
        let generation = generation
        webView.stopLoading()
        loadPhase = .loading(lastLoadedAt: loadPhase.lastLoadedAt)
        do {
            let forwarded = try await proxy.forward(url)
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            rememberOrigin(url, forwarded: forwarded)
            address = normalized
            webView.load(URLRequest(url: forwarded))
        } catch {
            guard self.generation == generation else { return }
            if error is CancellationError {
                loadPhase = loadPhase.settled()
            } else {
                fail(error.localizedDescription)
            }
            throw error
        }
    }

    private func observeTitle(_ webView: WKWebView) {
        titleObserver = webView.observe(\.title, options: [.initial, .new]) { @Sendable [weak self, weak webView] _, _ in
            Task { @MainActor in
                guard let self, let webView, self.webView === webView else { return }
                self.title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }
    }

    func reload() {
        loadPhase = loadPhase.clearingFailure()
        webView?.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === self.webView,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let proxy else { return .cancel }
        let generation = generation
        do {
            let forwarded = try await proxy.forward(url)
            guard self.generation == generation, webView === self.webView else { return .cancel }
            if forwarded != url {
                guard navigationAction.targetFrame?.isMainFrame != false else {
                    fail("This embedded page uses a different local server. Open its address in a new browser.")
                    return .cancel
                }
                var request = navigationAction.request
                rememberOrigin(url, forwarded: forwarded)
                request.url = forwarded
                webView.load(request)
                return .cancel
            }
            return .allow
        } catch {
            if self.generation == generation { fail(error.localizedDescription) }
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation?) {
        guard webView === self.webView else { return }
        loadPhase = .loading(lastLoadedAt: loadPhase.lastLoadedAt)
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        guard webView === self.webView else { return }
        // A failure reported mid-load (a cross-origin subframe) stays on screen.
        if loadPhase.isLoading { loadPhase = .loaded(Date()) }
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation?, withError error: Error) {
        show(error, from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
        show(error, from: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        fail("The page stopped responding. Reload to try again.")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if webView === self.webView, navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func show(_ error: Error, from webView: WKWebView) {
        guard webView === self.webView else { return }
        let error = error as NSError
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
        fail(error.localizedDescription)
        updateNavigation(webView)
    }

    private func fail(_ message: String) {
        loadPhase = loadPhase.failingVisibly(message)
    }

    private func updateNavigation(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        guard let url = webView.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let original = originalOrigins[originKey(url)] {
            components.scheme = original.scheme
            components.host = original.host
            components.port = original.port
        }
        address = components.url?.absoluteString ?? url.absoluteString
    }

    private func rememberOrigin(_ original: URL, forwarded: URL) {
        guard original != forwarded else { return }
        originalOrigins[originKey(forwarded)] = URLComponents(url: original, resolvingAgainstBaseURL: false)
    }

    private func originKey(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port.map(String.init) ?? "")"
    }
}
