import Foundation
import Testing
import Textual
import UIKit

@testable import Intent

@MainActor
struct MarkdownContentCacheTests {
    @Test func preparationPreservesTasksMermaidAndPendingStreamingVariants() throws {
        let cache = MarkdownContentCache()
        let source = "- [x] Done\n\n```mermaid\nflowchart TD\n A --> B\n```\n\n```mermaid\nflowchart TD"
        let first = cache.preparedContent(for: source)
        let reused = cache.preparedContent(for: source)
        #expect(reused.markdown == first.markdown)
        #expect(reused.mermaidSources == first.mermaidSources)
        #expect(reused.pendingDiagram?.markdown == first.pendingDiagram?.markdown)
        #expect(cache.preparedEntryCount == 1)
        #expect(first.markdown.hasPrefix("- ☑ Done"))
        #expect(first.mermaidSources["intent-mermaid-0"] == "flowchart TD\n A --> B")
        let pending = try #require(first.pendingDiagram)
        #expect(pending.markdown.hasPrefix("- ☑ Done"))
        #expect(pending.markdown.contains("Generating diagram"))
        #expect(pending.language == "intent-mermaid-1")

        let closed = cache.preparedContent(for: source + "\n```")
        #expect(closed.pendingDiagram == nil)
        #expect(closed.mermaidSources.count == 2)
        #expect(cache.preparedEntryCount == 2)
        // Streaming is a live choice by MarkdownTextView, not part of prepared state.
        #expect(cache.preparedContent(for: source).pendingDiagram?.markdown == pending.markdown)
    }

    @Test(arguments: [
        "## Heading\n\nA **bold** paragraph with `inline code`.\n\n- One\n- Two",
        "| Name | Value |\n| --- | --- |\n| Count | 12 |",
        "```swift\nlet answer = 42\n```",
        "[relative](docs/page) and ![image](intent://local/file/image.png)",
        "An unfinished **emphasis and [link](https://example.com",
        ""
    ])
    func cachedParserMatchesTextualDefaults(_ source: String) throws {
        let cache = MarkdownContentCache()
        let expected = try AttributedStringMarkdownParser.markdown().attributedString(for: source)
        #expect(try cache.attributedString(for: source) == expected)
        #expect(try cache.attributedString(for: source) == expected)
        #expect(cache.parsedEntryCount == 1)
    }

    @Test func semanticContentChangesAndUnicodeSpellingsHaveSeparateEntries() throws {
        let cache = MarkdownContentCache()
        let composed = "`caf\u{e9}`"
        let decomposed = "`cafe\u{301}`"
        for source in [composed, decomposed, "changed"] {
            let expected = try AttributedStringMarkdownParser.markdown().attributedString(for: source)
            let result = try cache.attributedString(for: source)
            #expect(Data(String(result.characters).utf8) == Data(String(expected.characters).utf8))
            _ = cache.preparedContent(for: source)
        }
        #expect(cache.parsedEntryCount == 3)
        #expect(cache.preparedEntryCount == 3)
    }

    @Test func callerStyleAndResolvedAttachmentsNeverEnterSharedSemanticResult() throws {
        let cache = MarkdownContentCache()
        let source = "![image](intent://local/file/image.png)"
        var resolved = try cache.attributedString(for: source)
        let expected = resolved
        #expect(resolved.runs.contains { $0.imageURL != nil })
        resolved.textual.attachment = AnyAttachment(IntentFileImageAttachment(image: UIImage(), altText: "image"))
        resolved.uiKit.foregroundColor = .red
        resolved.append(AttributedString(" caller edit"))

        let nextView = try cache.attributedString(for: source)
        #expect(nextView == expected)
        #expect(nextView != resolved)
        #expect(nextView.runs.allSatisfy { $0.textual.attachment == nil })
        #expect(nextView.runs.allSatisfy { $0.uiKit.foregroundColor == nil })
    }

    @Test func manyStreamingRevisionsBoundBothSharedStores() throws {
        let cache = MarkdownContentCache()
        let revisionCount = 300
        let costLimit = 10_485_760
        let preparedEntryLimit = 128
        let parsedEntryLimit = 256
        for revision in 1...revisionCount {
            let source = "Streaming revision \(revision)"
            let prepared = cache.preparedContent(for: source)
            let parsed = try cache.attributedString(for: prepared.markdown)
            #expect(String(parsed.characters) == source)
            #expect(cache.preparedEntryCount <= preparedEntryLimit)
            #expect(cache.parsedEntryCount <= parsedEntryLimit)
            #expect(cache.totalCost <= costLimit)
        }
        #expect(cache.preparedEntryCount == preparedEntryLimit)
        #expect(cache.parsedEntryCount == parsedEntryLimit)
    }
}
