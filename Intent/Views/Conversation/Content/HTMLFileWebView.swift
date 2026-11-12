import SwiftUI
import WebKit

/// An inert, isolated document, not a browser: no scripts, network or navigation.
/// Relative images, stylesheets and fonts load only from the report's own workspace.
struct HTMLFileWebView: UIViewRepresentable {
    let file: WorkspaceTextFile
    /// Location of `file`, workspace-relative or absolute; relative subresources resolve against it.
    let path: String
    let workspaceId: String
    let loader: WorkspaceFileImageLoader
    let rules: WKContentRuleList
    let onFailure: () -> Void

    static func blockingRules() async throws -> WKContentRuleList {
        let source = #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]"#
        guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "static-html-no-external-resources", encodedContentRuleList: source
        ) else { throw URLError(.cannotLoadFromNetwork) }
        return rules
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(resources: HTMLFileResourceHandler(workspaceId: workspaceId, loader: loader), onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator, rules: rules)
    }

    static func makeWebView(coordinator: Coordinator, rules: WKContentRuleList) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(rules)
        configuration.setURLSchemeHandler(coordinator.resources, forURLScheme: HTMLFileResourcePolicy.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsLinkPreview = false
        webView.accessibilityIdentifier = "html.content"
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(file, path: path, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.resources.cancelAll()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let resources: HTMLFileResourceHandler
        private let onFailure: () -> Void
        private var file: WorkspaceTextFile?
        /// The one navigation this page allows: its own initial load. Cleared once allowed.
        private var initialLoadURL: URL?

        init(resources: HTMLFileResourceHandler, onFailure: @escaping () -> Void) {
            self.resources = resources
            self.onFailure = onFailure
        }

        func load(_ file: WorkspaceTextFile, path: String, in webView: WKWebView) {
            guard self.file !== file else { return }
            self.file = file
            let baseURL = resources.beginPage(filePath: path)
            initialLoadURL = baseURL ?? URL(string: "about:blank")
            // Precede all untrusted markup, including any attacker-supplied CSP or <base>.
            // Inline styling, data images and the report's own relative images, stylesheets and fonts work;
            // scripts, frames, forms and every other load are denied.
            let prefix = """
            <!doctype html><head>
            <meta http-equiv="Content-Security-Policy" content="\(HTMLFileResourcePolicy.contentSecurityPolicy)">
            <meta http-equiv="x-dns-prefetch-control" content="off">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            </head>
            """
            webView.loadHTMLString(prefix + file.content, baseURL: baseURL)
        }

        // WebKit only calls the async form of this delegate method.
        // swiftlint:disable:next async_without_await
        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let initialLoadURL, action.navigationType == .other,
                  action.targetFrame?.isMainFrame == true,
                  action.request.url == initialLoadURL else { return .cancel }
            self.initialLoadURL = nil
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
