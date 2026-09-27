import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class WorkspaceBrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var errorMessage: String?
    private(set) var address = ""
    @ObservationIgnored private var proxy: (any BrowserProxySession)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var originalOrigins: [String: URLComponents] = [:]

    func open(_ browser: WorkspaceBrowser, connection: any SessionConnectionManaging) async {
        stop()
        let generation = generation
        isLoading = true
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
            webView.load(URLRequest(url: forwarded))
        } catch {
            guard self.generation == generation else { return }
            stop()
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func stop() {
        generation = UUID()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        errorMessage = nil
        address = ""
        originalOrigins.removeAll()
        if let proxy {
            self.proxy = nil
            Task { await proxy.close() }
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        errorMessage = nil
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
                    errorMessage = "This embedded page uses a different local server. Open its address in a new browser."
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
            if self.generation == generation {
                isLoading = false
                errorMessage = error.localizedDescription
            }
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard webView === self.webView else { return }
        errorMessage = nil
        isLoading = true
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard webView === self.webView else { return }
        isLoading = false
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        show(error, from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        show(error, from: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        isLoading = false
        errorMessage = "The page stopped responding. Reload to try again."
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
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
        isLoading = false
        errorMessage = error.localizedDescription
        updateNavigation(webView)
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
