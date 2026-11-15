import UIKit
import WebKit

/// One agent-controlled tab hosted on this device. The web view loads daemon-loopback
/// pages through its own browser tunnel, exactly like a user-opened workspace browser.
@MainActor
final class AgentBrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let defaultSize = CGSize(width: 390, height: 844)
    private static let navigationTimeout: Duration = .seconds(15)

    let tabId: String
    let workspaceId: String
    let webView: WKWebView
    var ownerAgentId: String?
    var ownerAgentName: String?
    var visibility: Visibility
    var emulatedSize: CGSize?
    private(set) var requestedURL: String?
    private(set) var address = ""
    private(set) var title = ""
    /// Called after any host-reported field changes, so the registry row stays current.
    var onChange: (@MainActor (AgentBrowserTab) -> Void)?

    private let proxy: any BrowserProxySession
    private var originalOrigins: [String: URLComponents] = [:]
    private var navigationWaiter: CheckedContinuation<Void, any Error>?
    private var titleObserver: NSKeyValueObservation?

    enum Visibility: String { case visible, hidden }

    init(
        tabId: String,
        workspaceId: String,
        proxy: any BrowserProxySession,
        ownerAgentId: String?,
        ownerAgentName: String?,
        visibility: Visibility,
        emulatedSize: CGSize?
    ) {
        self.tabId = tabId
        self.workspaceId = workspaceId
        self.proxy = proxy
        self.ownerAgentId = ownerAgentId
        self.ownerAgentName = ownerAgentName
        self.visibility = visibility
        self.emulatedSize = emulatedSize
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(origin: .zero, size: emulatedSize ?? Self.defaultSize), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        titleObserver = webView.observe(\.title, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.refreshTitle() }
        }
    }

    /// The registry report for this tab (§5.45 `BrowserTabInput`).
    var registryInput: [String: Any] {
        var tab: [String: Any] = [
            "tabId": tabId,
            "workspaceId": workspaceId,
            "url": address,
            "visibility": visibility.rawValue,
            "displayed": false
        ]
        if let requestedURL { tab["requestedUrl"] = requestedURL }
        if !title.isEmpty { tab["title"] = title }
        if let ownerAgentId { tab["ownerAgentId"] = ownerAgentId }
        if let ownerAgentName { tab["ownerAgentName"] = ownerAgentName }
        if let emulatedSize {
            tab["emulatedSize"] = ["width": Int(emulatedSize.width), "height": Int(emulatedSize.height)]
        }
        return tab
    }

    /// Loads `input` and waits until the main frame finishes or fails.
    func navigate(to input: String) async throws {
        let normalized = try WorkspaceBrowserURL.normalize(input)
        guard let url = URL(string: normalized) else { throw WorkspaceBrowserError.invalidURL }
        requestedURL = input
        let forwarded = try await proxy.forward(url)
        rememberOrigin(url, forwarded: forwarded)
        address = normalized
        try await waitForNavigation { webView.load(URLRequest(url: forwarded)) }
    }

    func resize(to size: CGSize?) {
        emulatedSize = size
        webView.frame.size = size ?? Self.defaultSize
        onChange?(self)
    }

    /// Like the desktop's CDP `Runtime.evaluate` with `returnByValue`: the completion value,
    /// promises are not awaited.
    func evaluate(_ expression: String) async throws -> Any {
        AgentBrowserJSON.sanitize(try await webView.evaluateExpression(expression))
    }

    func screenshot() async throws -> (png: Data, size: CGSize) {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await webView.snapshot(configuration)
        guard let png = image.pngData() else { throw ReverseRequestError.internalError("Screenshot encoding failed") }
        return (png, CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))
    }

    func close() async {
        navigationWaiter?.resume(throwing: CancellationError())
        navigationWaiter = nil
        titleObserver = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        await proxy.close()
    }

    private func waitForNavigation(_ start: () -> Void) async throws {
        navigationWaiter?.resume(throwing: CancellationError())
        navigationWaiter = nil
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.navigationTimeout)
            guard !Task.isCancelled else { return }
            self?.finishNavigation(nil)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            navigationWaiter = continuation
            start()
        }
    }

    private func finishNavigation(_ error: (any Error)?) {
        guard let waiter = navigationWaiter else { return }
        navigationWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    private func refreshTitle() {
        let next = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard next != title else { return }
        title = next
        onChange?(self)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == "about" { return .allow }
        guard ["http", "https"].contains(scheme) else { return .cancel }
        do {
            let forwarded = try await proxy.forward(url)
            guard forwarded != url else { return .allow }
            guard navigationAction.targetFrame?.isMainFrame != false else { return .cancel }
            var request = navigationAction.request
            rememberOrigin(url, forwarded: forwarded)
            request.url = forwarded
            webView.load(request)
            return .cancel
        } catch {
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        updateAddress(webView)
        finishNavigation(nil)
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation?, withError error: any Error) {
        failNavigation(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: any Error) {
        failNavigation(error, webView: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(ReverseRequestError.internalError("The page stopped responding."))
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    private func failNavigation(_ error: any Error, webView: WKWebView) {
        let error = error as NSError
        // A load replaced by a redirect or a newer load is not a failure of the tab.
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
        updateAddress(webView)
        finishNavigation(error)
    }

    private func updateAddress(_ webView: WKWebView) {
        guard let url = webView.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let original = originalOrigins[originKey(url)] {
            components.scheme = original.scheme
            components.host = original.host
            components.port = original.port
        }
        let next = components.url?.absoluteString ?? url.absoluteString
        guard next != address else { return }
        address = next
        onChange?(self)
    }

    private func rememberOrigin(_ original: URL, forwarded: URL) {
        guard original != forwarded else { return }
        originalOrigins[originKey(forwarded)] = URLComponents(url: original, resolvingAgainstBaseURL: false)
    }

    private func originKey(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port.map(String.init) ?? "")"
    }
}
