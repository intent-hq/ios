import Foundation
@testable import Intent
import SwiftUI
import Testing
import WebKit

@MainActor
struct MermaidWebViewTests {
    private static let viewport = CGRect(x: 0, y: 0, width: 390, height: 360)
    private static let pollInterval: Duration = .milliseconds(50)
    private static let replacementLimitSeconds = 8

    @Test func ignoresStaleAndMalformedMessages() {
        #expect(MermaidRenderState.message(["revision": "old", "height": 120.0], revision: "new") == nil)
        #expect(MermaidRenderState.message(["height": 120.0], revision: "new") == nil)
        #expect(MermaidRenderState.message(["revision": "new", "height": Double.infinity], revision: "new") == nil)
        #expect(MermaidRenderState.message(["revision": "new", "height": -1.0], revision: "new") == nil)
        #expect(MermaidRenderState.message(["revision": "new", "height": 120.0], revision: "new") == .rendered(120))
        #expect(MermaidRenderState.message(["revision": "new", "error": "Syntax error"], revision: "new")?.error != nil)
    }

    @Test(arguments: [false, true], [false, true])
    func bundledRendererDrawsOffline(dark: Bool, expanded: Bool) async throws {
        let source = "flowchart LR\n  start[Start] --> finish[Finish]"
        try await withRenderer(source: source, dark: dark, expanded: expanded) { webView, state in
            #expect(state.height != nil)
            #expect(state.error == nil)
            let result = try await webView.evaluateJavaScript("document.querySelector('svg')?.textContent")
            let labels = try #require(result as? String)
            #expect(labels.contains("Start"))
            #expect(labels.contains("Finish"))
            let fontLoaded = try await webView.evaluateJavaScript("document.fonts.check('13px Inter')")
            #expect(fontLoaded as? Bool == true)
        }
    }

    @Test func invalidSyntaxReportsFailure() async throws {
        try await withRenderer(source: "not a diagram", dark: false, expanded: false) { _, state in
            #expect(state.error == "Unable to draw this diagram.")
            #expect(!state.isLoading)
        }
    }

    enum WebKitFailure: CaseIterable {
        case processTermination, navigation, provisionalNavigation

        func trigger(webView: WKWebView, coordinator: MermaidWebView.Coordinator) {
            switch self {
            case .processTermination:
                coordinator.webViewWebContentProcessDidTerminate(webView)
            case .navigation:
                coordinator.webView(webView, didFail: nil, withError: URLError(.networkConnectionLost))
            case .provisionalNavigation:
                coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.cannotConnectToHost))
            }
        }
    }

    @Test(arguments: WebKitFailure.allCases, [false, true])
    func transientWebKitFailureRecovers(failure: WebKitFailure, alreadyRendered: Bool) async throws {
        try await withWebView { webView, coordinator, state in
            if alreadyRendered {
                try await waitForResult(state)
                try #require(state.wrappedValue.height != nil)
                _ = try await webView.evaluateJavaScript("window.previousPage = true")
            }
            failure.trigger(webView: webView, coordinator: coordinator)
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil, "Transient failure must recover: \(state.wrappedValue)")
            #expect(state.wrappedValue.error == nil)
            let previousPage = try await webView.evaluateJavaScript("window.previousPage === true")
            #expect(previousPage as? Bool == false, "Recovery must load a fresh page")
            let labels = try await webView.evaluateJavaScript("document.querySelector('svg')?.textContent")
            #expect((labels as? String)?.contains("Finish") == true)
        }
    }

    @Test func javaScriptCallFailureReloadsAndRendersCurrentSource() async throws {
        try await withWebView { webView, coordinator, state in
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil)
            _ = try await webView.evaluateJavaScript("window.renderMermaid = () => { throw new Error('WebKit test failure'); }; null;")
            coordinator.update(MermaidWebView(
                source: "flowchart LR\n A[Updated] --> B[Recovered]", dark: false, expanded: false, state: state
            ))
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil, "JavaScript call failure must recover")
            let labels = try await webView.evaluateJavaScript("document.querySelector('svg')?.textContent")
            #expect((labels as? String)?.contains("Recovered") == true)
        }
    }

    @Test func repeatedFailuresExhaustRecoveryBudget() async throws {
        try await withWebView { webView, coordinator, state in
            for _ in 0..<2 {
                coordinator.webViewWebContentProcessDidTerminate(webView)
                try await waitForResult(state)
                try #require(state.wrappedValue.height != nil, "Both automatic retries must be available")
            }
            coordinator.webViewWebContentProcessDidTerminate(webView)
            try await waitForResult(state)
            #expect(state.wrappedValue.error == "Unable to load this diagram. Try again.")
            // A late navigation completion must not resurrect an exhausted renderer.
            coordinator.webView(webView, didFinish: nil)
            try await waitForResult(state)
            #expect(state.wrappedValue.error == "Unable to load this diagram. Try again.")
        }
    }

    @Test func cancelledNavigationDoesNotConsumeRecoveryBudget() async throws {
        try await withWebView { webView, coordinator, state in
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil)
            _ = try await webView.evaluateJavaScript("window.previousPage = true")
            for _ in 0..<3 {
                coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
                coordinator.webView(webView, didFail: nil, withError: URLError(.cancelled))
            }
            try await waitForResult(state)
            #expect(state.wrappedValue.height != nil)
            let previousPage = try await webView.evaluateJavaScript("window.previousPage === true")
            #expect(previousPage as? Bool == true, "Cancelled loads must not reload the current page")
            coordinator.webViewWebContentProcessDidTerminate(webView)
            try await waitForResult(state)
            #expect(state.wrappedValue.height != nil)
        }
    }

    @Test(arguments: [false, true])
    func silentPageLoadReplacesWebViewAndIgnoresDiscardedCallbacks(duringRecovery: Bool) async throws {
        try await withWebView { webView, coordinator, state in
            if duringRecovery { coordinator.webViewWebContentProcessDidTerminate(webView) }
            webView.navigationDelegate = nil
            webView.stopLoading()
            let replacement = try await waitForReplacement(of: webView, coordinator: coordinator)
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil, "A silent page load must recover without user intervention")
            #expect(webView.superview == nil)
            #expect(replacement.frame == Self.viewport)
            #expect(replacement.configuration.websiteDataStore !== webView.configuration.websiteDataStore)
            _ = try await replacement.evaluateJavaScript("window.previousPage = true")
            coordinator.webView(webView, didFinish: nil)
            for failure in WebKitFailure.allCases { failure.trigger(webView: webView, coordinator: coordinator) }
            try await waitForResult(state)
            #expect(state.wrappedValue.height != nil, "Discarded views must not change the current renderer")
            let previousPage = try await replacement.evaluateJavaScript("window.previousPage === true")
            #expect(previousPage as? Bool == true, "Discarded callbacks must not reload the replacement")
        }
    }

    @Test func silentLoadsExhaustOnlyTwoRetries() async throws {
        var loadedViews: [WKWebView] = []
        try await withWebView(onWebViewAdded: { webView, _ in
            loadedViews.append(webView)
            webView.navigationDelegate = nil
            webView.stopLoading()
        }, check: { _, coordinator, state in
            try await waitForResult(state)
            #expect(loadedViews.count == 3, "The initial view and exactly two fresh-view retries must be attempted")
            #expect(state.wrappedValue.error == "Unable to load this diagram. Try again.")
            for webView in loadedViews {
                coordinator.webView(webView, didFinish: nil)
                coordinator.webViewWebContentProcessDidTerminate(webView)
            }
            try await waitForResult(state)
            #expect(loadedViews.count == 3, "Exhausted recovery must not create another view")
            #expect(state.wrappedValue.error == "Unable to load this diagram. Try again.")
        })
    }

    @Test func freshWebViewKeepsOriginalRenderDeadline() async throws {
        var firstLoad = true
        try await withWebView(onWebViewAdded: { webView, coordinator in
            if firstLoad {
                firstLoad = false
                webView.navigationDelegate = nil
                webView.stopLoading()
            } else {
                // Install before the tested navigation, not the factory's already-started load.
                webView.stopLoading()
                webView.configuration.userContentController.addUserScript(WKUserScript(
                    source: "Object.defineProperty(window, 'renderMermaid', { value: () => new Promise(resolve => setTimeout(resolve, 60000)) });",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
                coordinator.loadPage()
            }
        }, check: { webView, coordinator, state in
            let started = ContinuousClock.now
            let deadline = started + MermaidAppearance.renderTimeout + .seconds(1)
            _ = try await waitForReplacement(of: webView, coordinator: coordinator)
            while state.wrappedValue.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: Self.pollInterval)
            }
            #expect(state.wrappedValue.error == "Unable to load this diagram. Try again.", "Replacement must not reset the deadline")
            #expect(started.duration(to: .now) >= MermaidAppearance.renderTimeout - .seconds(1), "The stalled renderer must reach the original deadline")
        })
    }

    @Test func recoveryKeepsOriginalRenderDeadline() async throws {
        try await withWebView { webView, coordinator, state in
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil)
            let stalledRenderer = """
                Object.defineProperty(window, 'renderMermaid', {
                    value: () => new Promise(resolve => setTimeout(resolve, 60000))
                }); null;
                """
            _ = try await webView.evaluateJavaScript(stalledRenderer)
            webView.configuration.userContentController.addUserScript(WKUserScript(
                source: stalledRenderer, injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
            let deadline = ContinuousClock.now + MermaidAppearance.renderTimeout + .seconds(2)
            coordinator.update(MermaidWebView(source: "flowchart LR\n A --> B", dark: false, expanded: false, state: state))
            try await Task.sleep(for: MermaidAppearance.renderTimeout / 2)
            #expect(state.wrappedValue.isLoading)
            coordinator.webViewWebContentProcessDidTerminate(webView)
            while state.wrappedValue.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: Self.pollInterval)
            }
            #expect(state.wrappedValue.error == "Unable to load this diagram. Try again.", "Recovery must not reset the deadline")
        }
    }

    @Test func staleJavaScriptFailureDoesNotReloadNewRevision() async throws {
        try await withWebView { webView, coordinator, state in
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil)
            _ = try await webView.evaluateJavaScript("""
                window.originalRender = window.renderMermaid;
                window.renderMermaid = request => request.source.includes('Obsolete')
                    ? new Promise((_, reject) => { window.rejectObsolete = reject; })
                    : window.originalRender(request);
                null;
                """)
            coordinator.update(MermaidWebView(source: "flowchart LR\n A[Obsolete]", dark: false, expanded: false, state: state))
            let deadline = ContinuousClock.now + MermaidAppearance.renderTimeout
            var obsoleteStarted = false
            repeat {
                try await Task.sleep(for: Self.pollInterval)
                obsoleteStarted = try await webView.evaluateJavaScript("typeof window.rejectObsolete === 'function'") as? Bool == true
            } while !obsoleteStarted && ContinuousClock.now < deadline
            try #require(obsoleteStarted)
            coordinator.update(MermaidWebView(source: "flowchart LR\n A[Current]", dark: false, expanded: false, state: state))
            try await waitForResult(state)
            try #require(state.wrappedValue.height != nil)
            _ = try await webView.evaluateJavaScript("window.rejectObsolete(new Error('Obsolete failure')); window.previousPage = true")
            try await waitForResult(state)
            let previousPage = try await webView.evaluateJavaScript("window.previousPage === true")
            #expect(previousPage as? Bool == true, "An obsolete call must not reload the current page")
            #expect(state.wrappedValue.height != nil)
        }
    }

    @Test func wideDiagramKeepsReadableScaleAndCanScroll() async throws {
        let source = "flowchart LR\n A[First step] --> B[Second step] --> C[Third step] --> D[Fourth step]"
        try await withRenderer(source: source, dark: false, expanded: false) { webView, state in
            #expect(state.error == nil)
            let width = try await webView.evaluateJavaScript("document.documentElement.scrollWidth")
            let scrollWidth = try #require(width as? Double)
            #expect(scrollWidth > Double(Self.viewport.width))
            let scale = try await webView.evaluateJavaScript("window.visualViewport.scale")
            let viewportScale = try #require(scale as? Double)
            #expect(viewportScale >= 1)
        }
    }

    @Test func diagramSourceCannotExecuteJavaScript() async throws {
        let source = """
        flowchart LR
          node["</script><script>window.diagramInjected = true</script>"]
        """
        try await withRenderer(source: source, dark: false, expanded: false) { webView, state in
            #expect(!state.isLoading)
            let injected = try await webView.evaluateJavaScript("window.diagramInjected === true")
            #expect(injected as? Bool == false)
        }
    }
}

extension MermaidWebViewTests {
    private func withRenderer(
        source: String,
        dark: Bool,
        expanded: Bool,
        check: (WKWebView, MermaidRenderState) async throws -> Void
    ) async throws {
        try await withWebView(source: source, dark: dark, expanded: expanded) { webView, _, state in
            try await waitForResult(state)
            try await check(webView, state.wrappedValue)
        }
    }

    private func withWebView(
        source: String = "flowchart LR\n start[Start] --> finish[Finish]",
        dark: Bool = false,
        expanded: Bool = false,
        onWebViewAdded: ((WKWebView, MermaidWebView.Coordinator) -> Void)? = nil,
        check: (WKWebView, MermaidWebView.Coordinator, Binding<MermaidRenderState>) async throws -> Void
    ) async throws {
        _ = try #require(MermaidWebView.pageURL, "Mermaid folder must be copied into the app bundle")
        let coordinator = MermaidWebView.Coordinator()
        let webView = MermaidWebView.makeWebView(coordinator: coordinator)
        let container = WebViewContainer(frame: Self.viewport)
        container.onWebViewAdded = { onWebViewAdded?($0, coordinator) }
        webView.frame = Self.viewport
        container.addSubview(webView)
        var state = MermaidRenderState.loading
        let binding = Binding(get: { state }, set: { state = $0 })
        coordinator.update(MermaidWebView(source: source, dark: dark, expanded: expanded, state: binding))
        defer {
            MermaidWebView.dismantleUIView(coordinator.webView ?? webView, coordinator: coordinator)
            withExtendedLifetime(container) {}
        }
        try await check(webView, coordinator, binding)
    }

    private final class WebViewContainer: UIView {
        var onWebViewAdded: ((WKWebView) -> Void)?

        override func didAddSubview(_ subview: UIView) {
            super.didAddSubview(subview)
            if let webView = subview as? WKWebView { onWebViewAdded?(webView) }
        }
    }

    private func waitForReplacement(of oldView: WKWebView, coordinator: MermaidWebView.Coordinator) async throws -> WKWebView {
        let replacementLimit: Duration = .seconds(Self.replacementLimitSeconds)
        let deadline = ContinuousClock.now + replacementLimit
        while coordinator.webView === oldView, ContinuousClock.now < deadline {
            try await Task.sleep(for: Self.pollInterval)
        }
        try #require(coordinator.webView !== oldView, "A no-progress load must replace the stuck web view before the total deadline")
        return try #require(coordinator.webView)
    }

    private func waitForResult(_ state: Binding<MermaidRenderState>) async throws {
        let deadline = ContinuousClock.now + MermaidAppearance.renderTimeout + .seconds(1)
        repeat {
            try await Task.sleep(for: Self.pollInterval)
        } while state.wrappedValue.isLoading && ContinuousClock.now < deadline
        try #require(!state.wrappedValue.isLoading, "Renderer must report a result or an error")
    }
}
