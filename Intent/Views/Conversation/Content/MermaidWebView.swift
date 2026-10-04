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
            return .failed("Unable to draw this diagram. You can still read its source.")
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
        webView.allowsLinkPreview = false
        coordinator.webView = webView
        if let url = Self.pageURL {
            webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.overrideUserInterfaceStyle = dark ? .dark : .light
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
        private var renderTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        func update(_ view: MermaidWebView) {
            let changed = parent?.source != view.source || parent?.dark != view.dark || parent?.expanded != view.expanded
            parent = view
            guard changed else { return }
            revision = UUID().uuidString
            renderTask?.cancel()
            timeoutTask?.cancel()
            publish(.loading)
            guard MermaidWebView.pageURL != nil else {
                publish(.failed("The diagram renderer is unavailable. You can still read its source."))
                return
            }
            startTimeout()
            if ready { render() }
        }

        func stop() {
            renderTask?.cancel()
            timeoutTask?.cancel()
            parent = nil
            webView = nil
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
            guard webView === self.webView else { return }
            ready = true
            render()
        }

        func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == MermaidWebView.pageURL
                ? .allow : .cancel
        }

        func webView(_: WKWebView, didFail _: WKNavigation?, withError _: Error) {
            fail()
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError _: Error) {
            fail()
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) {
            ready = false
            fail()
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let state = MermaidRenderState.message(message.body, revision: revision) else { return }
            timeoutTask?.cancel()
            publish(state)
        }

        private func render() {
            guard let parent, let webView else { return }
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
                    guard let self, revision == currentRevision, !Task.isCancelled else { return }
                    fail()
                }
            }
        }

        private func startTimeout() {
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: MermaidAppearance.renderTimeout) } catch { return }
                self?.fail()
            }
        }

        private func fail() {
            timeoutTask?.cancel()
            publish(.failed("Unable to load this diagram. Try again or read its source."))
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
