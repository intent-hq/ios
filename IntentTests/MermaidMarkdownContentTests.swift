import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import Intent

struct MermaidMarkdownContentTests {
    private static let diagram = "flowchart LR\nA --> B"

    @Test func referenceLinksResolveAcrossDiagram() throws {
        let content = "[Before][guide]\n\n```mermaid\n\(Self.diagram)\n```\n\n[After][guide]\n\n[guide]: https://example.com/guide"
        let prepared = MermaidMarkdownContent(content)
        #expect(Array(prepared.sources.values) == [Self.diagram])
        let parsed = try AttributedString(markdown: prepared.markdown)
        let links = parsed.runs.compactMap { $0.link?.absoluteString }
        #expect(links == ["https://example.com/guide", "https://example.com/guide"])
    }

    @Test func incompleteStreamingFenceBecomesDiagramOnlyWhenClosed() {
        let partial = "First\n\n```mermaid\n\(Self.diagram)"
        let incomplete = MermaidMarkdownContent(partial)
        #expect(incomplete.markdown == partial)
        #expect(incomplete.sources.isEmpty)

        let complete = MermaidMarkdownContent(partial + "\n```")
        #expect(Array(complete.sources.values) == [Self.diagram])
        let continued = MermaidMarkdownContent(partial + "\n```\n\nMore text\n\n```mermaid\ngraph TD")
        #expect(continued.sources == complete.sources)
        #expect(continued.markdown.hasSuffix("```mermaid\ngraph TD"))
    }

    @Test(arguments: [
        "```swift\nlet answer = 42\n```",
        "````markdown\n```mermaid\nflowchart LR\nA --> B\n```\n````",
        "~~~text\n```mermaid\nflowchart LR\nA --> B\n```\n~~~",
        "```Mermaid\nflowchart LR\nA --> B\n```",
        "    ```mermaid\n    flowchart LR\n    A --> B\n    ```",
        "A paragraph with `mermaid` and [a link](https://example.com)."
    ])
    func ordinaryMarkdownStaysUnchanged(_ content: String) {
        let prepared = MermaidMarkdownContent(content)
        #expect(prepared.markdown == content)
        #expect(prepared.sources.isEmpty)
    }

    @Test func indentedTildeFencePreservesSourceAndLineEndings() throws {
        let content = "Before\r\n\r\n  ~~~~mermaid\r\n  flowchart LR\r\n  A[\"- [x] source\"] --> B\r\n  ~~~~~\r\n\r\nAfter\r\n"
        let prepared = MermaidMarkdownContent(content)
        let key = try #require(prepared.sources.keys.first)
        #expect(prepared.sources[key] == "flowchart LR\nA[\"- [x] source\"] --> B")
        #expect(prepared.markdown == content.replacingOccurrences(of: "~~~~mermaid", with: "~~~~" + key))
    }

    @Test func privateLanguageKeysCannotCollideWithAuthoredCode() throws {
        let content = "```intent-mermaid-0\nordinary code\n```\n\n```mermaid\n\(Self.diagram)\n```"
        let prepared = MermaidMarkdownContent(content)
        let key = try #require(prepared.sources.keys.first)
        #expect(key != "intent-mermaid-0")
        #expect(prepared.markdown.hasPrefix("```intent-mermaid-0\nordinary code\n```"))
        #expect(prepared.sources[key] == Self.diagram)
    }

    @MainActor
    @Test func markdownCodeStyleMountsOnlyCompletedDiagrams() async throws {
        let complete = "Before\n\n```mermaid\n\(Self.diagram)\n```\n\nAfter"
        let incomplete = "Before\n\n```mermaid\n\(Self.diagram)"
        #expect(try await webViewCount(MarkdownTextView(text: complete)) == 1)
        #expect(try await webViewCount(MarkdownTextView(text: incomplete)) == 0)
        #expect(try await webViewCount(MarkdownTextView(text: "```swift\nlet answer = 42\n```")) == 0)
    }

    @MainActor
    @Test func structuredCodeWaitsForStreamingToFinish() async throws {
        let code = CodeBlockView(code: Self.diagram, language: "mermaid")
        #expect(try await webViewCount(code.environment(\.assistantMessageStreaming, true)) == 0)
        #expect(try await webViewCount(code.environment(\.assistantMessageStreaming, false)) == 1)
        #expect(try await webViewCount(CodeBlockView(code: "let answer = 42", language: "swift")) == 0)
    }

    @MainActor
    private func webViewCount(_ content: some View) async throws -> Int {
        try await SyntheticBadgeHost.render(content, width: 390, height: 700) { view, _ in
            Self.countWebViews(in: view)
        }
    }

    @MainActor
    private static func countWebViews(in view: UIView) -> Int {
        (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + countWebViews(in: $1) }
    }
}
