import SwiftUI
import WebKit

/// An inert, isolated document, not a browser: no scripts, external resources or navigation.
struct HTMLFileWebView: UIViewRepresentable {
    let file: WorkspaceTextFile
    let rules: WKContentRuleList
    let onFailure: () -> Void

    static func blockingRules() async throws -> WKContentRuleList {
        let source = #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]"#
        guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "static-html-no-external-resources", encodedContentRuleList: source
        ) else { throw URLError(.cannotLoadFromNetwork) }
        return rules
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator, rules: rules)
    }

    static func makeWebView(coordinator: Coordinator, rules: WKContentRuleList) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsLinkPreview = false
        webView.accessibilityIdentifier = "html.content"
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(file, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator _: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onFailure: () -> Void
        private var file: WorkspaceTextFile?
        private var awaitingInitialLoad = false

        init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }

        func load(_ file: WorkspaceTextFile, in webView: WKWebView) {
            guard self.file !== file else { return }
            self.file = file
            awaitingInitialLoad = true
            // Precede all untrusted markup, including any attacker-supplied CSP or <base>.
            // Inline styling/data images work; frames, fonts, forms and every other load are denied.
            let prefix = """
            <!doctype html><head>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
            <meta http-equiv="x-dns-prefetch-control" content="off">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            </head>
            """
            webView.loadHTMLString(prefix + file.content, baseURL: nil)
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard awaitingInitialLoad, action.navigationType == .other,
                  action.targetFrame?.isMainFrame == true,
                  action.request.url?.absoluteString == "about:blank" else { return .cancel }
            awaitingInitialLoad = false
            return .allow
        }

        func webView(_: WKWebView, didFail _: WKNavigation?, withError error: Error) {
            failUnlessCancelled(error)
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
            failUnlessCancelled(error)
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) { onFailure() }

        private func failUnlessCancelled(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure()
        }
    }
}
