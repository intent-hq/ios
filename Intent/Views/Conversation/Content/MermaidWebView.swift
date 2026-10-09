import SwiftUI
import WebKit

enum MermaidRenderState: Equatable {
    case failed(String)
    case loading
    case rendered(CGFloat)

    var isLoading: Bool { self == .loading }

    var height: CGFloat? {
        guard case .rendered(let height) = self else { return nil }
        return height
    }

    var error: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }

    static func message(_ body: Any, revision: String) -> Self? {
        guard let body = body as? [String: Any], body["revision"] as? String == revision else { return nil }
        if body["error"] is String {
            return .failed("Unable to draw this diagram.")
        }
        guard let height = body["height"] as? Double, height.isFinite, height > 0 else { return nil }
        return .rendered(CGFloat(height))
    }
}

struct MermaidWebView: UIViewRepresentable {
    private static let websiteDataStore = WKWebsiteDataStore.nonPersistent()

    let source: String
    let dark: Bool
    let expanded: Bool
    @Binding var state: MermaidRenderState

    static var pageURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Mermaid")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.websiteDataStore
        configuration.userContentController.add(coordinator, name: "mermaid")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isDirectionalLockEnabled = false
        webView.scrollView.bouncesZoom = true
        webView.allowsLinkPreview = false
        webView.accessibilityIdentifier = "mermaid.webview"
        coordinator.webView = webView
        coordinator.loadPage()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.overrideUserInterfaceStyle = dark ? .dark : .light
        webView.accessibilityIdentifier = expanded ? "mermaid.fullscreen.webview" : "mermaid.webview"
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mermaid")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var parent: MermaidWebView?
        private var revision = UUID().uuidString
        private var ready = false
        private var hasFailed = false
        private var recoveryAttempts = 0
        private var navigation: WKNavigation?
        private var renderTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        func loadPage() {
            guard let webView, let url = MermaidWebView.pageURL else { return }
            ready = false
            navigation = webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
        }

        func update(_ view: MermaidWebView) {
            let changed = parent?.source != view.source || parent?.dark != view.dark || parent?.expanded != view.expanded
            parent = view
            guard changed else { return }
            revision = UUID().uuidString
            renderTask?.cancel()
            timeoutTask?.cancel()
            recoveryAttempts = 0
            hasFailed = false
            publish(.loading)
            guard MermaidWebView.pageURL != nil else {
                publish(.failed("The diagram renderer is unavailable."))
                return
            }
            startTimeout()
            if ready {
                render()
            } else if navigation == nil {
                loadPage()
            }
        }

        func stop() {
            renderTask?.cancel()
            timeoutTask?.cancel()
            navigation = nil
            parent = nil
            webView = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard webView === self.webView, !hasFailed,
                  navigation == nil || navigation === self.navigation else { return }
            ready = true
            render()
        }

        func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame == true,
                  let url = navigationAction.request.url, url.isFileURL,
                  url.standardizedFileURL == MermaidWebView.pageURL?.standardizedFileURL else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            navigationFailed(webView, navigation: navigation, error: error, reason: "navigation failed")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            navigationFailed(webView, navigation: navigation, error: error, reason: "page load failed")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === self.webView else { return }
            recover(reason: "web content process terminated", error: WKError(.webContentProcessTerminated))
        }

        private func navigationFailed(_ webView: WKWebView, navigation: WKNavigation?, error: Error, reason: String) {
            guard webView === self.webView, navigation == nil || navigation === self.navigation else { return }
            let nsError = error as NSError
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            recover(reason: reason, error: error)
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready, !hasFailed, message.webView === webView, message.frameInfo.isMainFrame,
                  let state = MermaidRenderState.message(message.body, revision: revision) else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            hasFailed = state.error != nil
            publish(state)
        }

        private func render() {
            guard ready, !hasFailed, let parent, let webView else { return }
            let currentRevision = revision
            let arguments: [String: Any] = [
                "request": ["source": parent.source, "dark": parent.dark, "expanded": parent.expanded, "revision": currentRevision]
            ]
            renderTask?.cancel()
            renderTask = Task { [weak self, weak webView] in
                guard let webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "await window.renderMermaid(request);",
                        arguments: arguments,
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    guard let self, revision == currentRevision, !Task.isCancelled,
                          !(error is CancellationError) else { return }
                    recover(reason: "JavaScript call failed", error: error)
                }
            }
        }

        private func startTimeout() {
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: MermaidAppearance.renderTimeout) } catch { return }
                AppLog.userInterface.error("Mermaid rendering timed out")
                self?.fail()
            }
        }

        private func recover(reason: String, error: Error) {
            guard parent != nil, webView != nil, !hasFailed else { return }
            let nsError = error as NSError
            AppLog.userInterface.error("Mermaid \(reason): domain=\(nsError.domain) code=\(nsError.code) retries=\(recoveryAttempts)")
            guard recoveryAttempts < 2 else {
                fail()
                return
            }
            recoveryAttempts += 1
            renderTask?.cancel()
            revision = UUID().uuidString
            publish(.loading)
            // Keep the pending render's deadline. A crash after success starts a new bounded recovery window.
            if timeoutTask == nil { startTimeout() }
            loadPage()
        }

        private func fail() {
            hasFailed = true
            ready = false
            revision = UUID().uuidString
            renderTask?.cancel()
            timeoutTask?.cancel()
            timeoutTask = nil
            navigation = nil
            webView?.stopLoading()
            publish(.failed("Unable to load this diagram. Try again."))
        }

        private func publish(_ state: MermaidRenderState) {
            let currentRevision = revision
            Task { @MainActor [weak self] in
                guard let self, revision == currentRevision else { return }
                parent?.state = state
            }
        }
    }
}
