import Foundation
@testable import Intent
import SwiftUI
import Testing
import WebKit

@MainActor
struct MermaidWebViewTests {
    private static let viewport = CGRect(x: 0, y: 0, width: 390, height: 360)
    private static let pollInterval: Duration = .milliseconds(50)

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
            #expect(state.error != nil)
            #expect(!state.isLoading)
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

    private func withRenderer(
        source: String,
        dark: Bool,
        expanded: Bool,
        check: (WKWebView, MermaidRenderState) async throws -> Void
    ) async throws {
        _ = try #require(MermaidWebView.pageURL, "Mermaid folder must be copied into the app bundle")
        let coordinator = MermaidWebView.Coordinator()
        let webView = MermaidWebView.makeWebView(coordinator: coordinator)
        webView.frame = Self.viewport
        var state = MermaidRenderState.loading
        let binding = Binding(get: { state }, set: { state = $0 })
        coordinator.update(MermaidWebView(source: source, dark: dark, expanded: expanded, state: binding))
        defer { MermaidWebView.dismantleUIView(webView, coordinator: coordinator) }
        let deadline = ContinuousClock.now + MermaidAppearance.renderTimeout + .seconds(1)
        while state.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: Self.pollInterval)
        }
        try #require(!state.isLoading, "Renderer must report a result or an error")
        try await check(webView, state)
    }
}
