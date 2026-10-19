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
            let result = try await MermaidJavaScriptProbe.evaluate("document.querySelector('svg')?.textContent", in: webView)
            let labels = try #require(result as? String)
            #expect(labels.contains("Start"))
            #expect(labels.contains("Finish"))
            let fontLoaded = try await MermaidJavaScriptProbe.evaluate("document.fonts.check('13px Inter')", in: webView)
            #expect(fontLoaded as? Bool == true)
        }
    }

    @Test func invalidSyntaxReportsFailure() async throws {
        try await withRenderer(source: "not a diagram", dark: false, expanded: false, expectsFailure: true) { _, state in
            #expect(state == .failed("Unable to draw this diagram."))
            #expect(!state.isLoading)
        }
    }

    @Test func wideDiagramKeepsReadableScaleAndCanScroll() async throws {
        let source = "flowchart LR\n A[First step] --> B[Second step] --> C[Third step] --> D[Fourth step]"
        try await withRenderer(source: source, dark: false, expanded: false) { webView, state in
            #expect(state.error == nil)
            let width = try await MermaidJavaScriptProbe.evaluate("document.documentElement.scrollWidth", in: webView)
            let scrollWidth = try #require(width as? Double)
            #expect(scrollWidth > Double(Self.viewport.width))
            let scale = try await MermaidJavaScriptProbe.evaluate("window.visualViewport.scale", in: webView)
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
            let injected = try await MermaidJavaScriptProbe.evaluate("window.diagramInjected === true", in: webView)
            #expect(injected as? Bool == false)
        }
    }

    private func withRenderer(
        source: String,
        dark: Bool,
        expanded: Bool,
        expectsFailure: Bool = false,
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
        if !expectsFailure {
            try #require(state.height != nil, "Mermaid rendering failed: \(state.error ?? "missing height")")
        }
        try await check(webView, state)
    }
}

@MainActor
private enum MermaidJavaScriptProbe {
    typealias Completion = @MainActor @Sendable (Any?, (any Error)?) -> Void

    private static let defaultTimeoutSeconds = 5
    private static let pollIntervalMilliseconds = 10
    private static let pollInterval: Duration = .milliseconds(pollIntervalMilliseconds)

    static func evaluate(_ expression: String, in webView: WKWebView) async throws -> Any? {
        try await waitForResult { completion in
            webView.evaluateJavaScript(expression, completionHandler: completion)
        }
    }

    static func waitForResult(
        timeout: Duration = .seconds(defaultTimeoutSeconds),
        start: (@escaping Completion) -> Void
    ) async throws -> Any? {
        try Task.checkCancellation()
        let reply = Reply()
        let deadline = ContinuousClock.now + timeout
        start { [weak reply] value, error in
            guard let reply, reply.result == nil else { return }
            reply.result = error.map { .failure($0) } ?? .success(value)
        }
        // A WebKit async call may never resume, even after its task is cancelled.
        while reply.result == nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: Self.pollInterval)
        }
        try Task.checkCancellation()
        return try reply.result?.get()
    }

    private final class Reply {
        var result: Result<Any?, any Error>?
    }
}

@MainActor
struct MermaidJavaScriptProbeTests {
    @Test(arguments: [false, true])
    func preservesValuesAndNil(isNil: Bool) async throws {
        let result = try await MermaidJavaScriptProbe.waitForResult { completion in
            completion(isNil ? nil : 42, nil)
        }
        #expect(isNil ? result == nil : result as? Int == 42)
    }

    @Test func propagatesWebKitErrors() async {
        do {
            _ = try await MermaidJavaScriptProbe.waitForResult { completion in
                completion(nil, URLError(.cannotLoadFromNetwork))
            }
            Issue.record("The probe must propagate the WebKit error")
        } catch {
            #expect((error as? URLError)?.code == .cannotLoadFromNetwork)
        }
    }

    @Test func acceptsAsynchronousCallback() async throws {
        let result = try await MermaidJavaScriptProbe.waitForResult { completion in
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(20))
                    completion("ready", nil)
                } catch {
                    completion(nil, error)
                }
            }
        }
        #expect(result as? String == "ready")
    }

    @Test func missingCallbackTimesOutAndLateCallbackIsHarmless() async throws {
        var late: MermaidJavaScriptProbe.Completion?
        do {
            _ = try await MermaidJavaScriptProbe.waitForResult(timeout: .milliseconds(30)) { late = $0 }
            Issue.record("A missing callback must time out")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        let completion = try #require(late)
        completion("too late", nil)
        completion(nil, URLError(.cancelled))
        let result = try await MermaidJavaScriptProbe.waitForResult { $0("next probe", nil) }
        #expect(result as? String == "next probe")
    }

    @Test func cancellationStopsWaitingWithoutACallback() async throws {
        var late: MermaidJavaScriptProbe.Completion?
        let waiter = Task { @MainActor in
            try await MermaidJavaScriptProbe.waitForResult(timeout: .seconds(1)) { late = $0 } as? String
        }
        defer { waiter.cancel() }
        let deadline = ContinuousClock.now + .seconds(1)
        while late == nil, ContinuousClock.now < deadline { await Task.yield() }
        let completion = try #require(late)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        completion("too late", nil)
    }

    @Test func cancelledProbeDoesNotStartWebKitWork() async {
        var started = false
        let waiter = Task { @MainActor in
            try await MermaidJavaScriptProbe.waitForResult { completion in
                started = true
                completion(nil, nil)
            } as? String
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!started)
    }
}
