import SwiftUI
import Testing
import Textual
import UIKit

@testable import Intent

struct MarkdownTextViewTests {
    private func replaced(_ text: String) -> String {
        MarkdownTextView.replacingTaskListMarkers(text)
    }

    @Test func uncheckedMarkerBecomesEmptyCheckbox() {
        #expect(replaced("- [ ] buy milk") == "- ☐ buy milk")
    }

    @Test func checkedMarkerBecomesFilledCheckbox() {
        #expect(replaced("- [x] buy milk") == "- ☑ buy milk")
        #expect(replaced("- [X] buy milk") == "- ☑ buy milk")
    }

    @Test func starAndPlusBulletsAreSupported() {
        #expect(replaced("* [ ] a") == "* ☐ a")
        #expect(replaced("+ [x] b") == "+ ☑ b")
    }

    @Test func indentedItemsKeepIndentation() {
        #expect(replaced("  - [ ] nested") == "  - ☐ nested")
    }

    @Test func orderedTaskItemsAreConverted() {
        #expect(replaced("1. [ ] ordered") == "1. ☐ ordered")
        #expect(replaced("12) [x] ordered") == "12) ☑ ordered")
    }

    @Test func blockquotedTaskItemsAreConverted() {
        #expect(replaced("> - [x] quoted") == "> - ☑ quoted")
        #expect(replaced("> > - [ ] nested quote") == "> > - ☐ nested quote")
    }

    @Test func nestedTasksInsideListsAreConverted() {
        let text = "- [ ] parent\n    - [x] child\n\t- [ ] tabbed child"
        #expect(replaced(text) == "- ☐ parent\n    - ☑ child\n\t- ☐ tabbed child")
    }

    @Test func indentedCodeBlocksAreSkipped() {
        let text = "some prose\n\n    - [ ] example"
        #expect(replaced(text) == text)
        #expect(replaced("\t- [x] tab code") == "\t- [x] tab code")
    }

    @Test func indentedBackticksAreNotFences() {
        let text = "some prose\n\n    ```\n- [ ] real task"
        #expect(replaced(text) == "some prose\n\n    ```\n- ☐ real task")
    }

    @Test func nonTaskListLinesAreUntouched() {
        #expect(replaced("- [link](https://example.com)") == "- [link](https://example.com)")
        #expect(replaced("plain [x] text") == "plain [x] text")
        #expect(replaced("- regular item") == "- regular item")
    }

    @Test func fencedCodeBlocksAreSkipped() {
        let text = """
            - [ ] real task
            ```
            - [ ] inside fence
            ```
            - [x] after fence
            """
        let expected = """
            - ☐ real task
            ```
            - [ ] inside fence
            ```
            - ☑ after fence
            """
        #expect(replaced(text) == expected)
    }

    @Test func mismatchedFenceMarkersDoNotClose() {
        let text = "```\n~~~\n- [ ] still fenced\n```\n- [x] out"
        #expect(replaced(text) == "```\n~~~\n- [ ] still fenced\n```\n- ☑ out")
    }

    @Test func tildeFencesAreSkipped() {
        let text = "~~~\n- [ ] inside\n~~~"
        #expect(replaced(text) == text)
    }

    @Test func shorterInnerFenceDoesNotExposeCodeAsTasks() {
        let text = "````mermaid\n```\n- [x] source\n````\n- [ ] task"
        #expect(replaced(text) == "````mermaid\n```\n- [x] source\n````\n- ☐ task")
    }

    @Test func carriageReturnsDoNotPreventFenceClosure() {
        let text = "```mermaid\r\n- [x] source\r\n```\r\n- [ ] task\r\n"
        #expect(replaced(text) == "```mermaid\r\n- [x] source\r\n```\r\n- ☐ task\r\n")
    }

    @Test func textWithoutBracketsIsReturnedVerbatim() {
        let text = "just some prose\nwith two lines"
        #expect(replaced(text) == text)
    }

    // MARK: - Attachment tap routing

    @Test func tappedIntentFileImageAttachmentYieldsItsImage() {
        let image = UIImage()
        let attachment = AnyAttachment(IntentFileImageAttachment(image: image, altText: "alt"))
        #expect(MarkdownTextView.lightboxImage(for: attachment) === image)
    }

    // A lazy transcript can measure a new row before it appears or receives callbacks.
    @MainActor
    @Test(arguments: [
        "A complete paragraph must participate in the first sizing pass.",
        "## Heading\n\nA **bold** paragraph with `inline code`.\n\n- One\n- Two"
    ])
    func firstSizingPassContainsMarkdown(_ markdown: String) {
        let controller = UIHostingController(rootView: MarkdownTextView(text: markdown))
        let size = controller.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        #expect(size.height.isFinite && size.height > 0)
        #expect(size.width.isFinite && size.width > 0)
    }

    // Fixed input must not grow or shrink after its initial natural-height measurement.
    @MainActor
    @Test(arguments: [
        "First paragraph.\n\nSecond paragraph.",
        "## Heading\n\nA paragraph below the heading.",
        "1. First item\n2. Second item\n\nLast paragraph.",
        "| Stage | Result |\n| --- | --- |\n| Layout | Stable height |\n| Text | Complete content |",
        "Before code.\n\n```swift\nlet answer = 42\n```\n\nAfter code."
    ])
    func unchangedMarkdownKeepsItsInitialHeight(_ markdown: String) async throws {
        var heights: [CGFloat] = []
        let view = MarkdownTextView(text: markdown)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.append($0) }
            .environment(\.dynamicTypeSize, .large)
        try await SyntheticBadgeHost.render(view, width: 320, height: 700) { _, _ in
            let first = try #require(heights.first)
            #expect(first > 0)
            #expect(heights.allSatisfy { abs($0 - first) < 1 }, "Natural heights: \(heights)")
        }
    }

    @MainActor
    @Test func renderedMarkdownKeepsCodeMonospacedAndProseScalable() async throws {
        let narrow = "iiiiiiii"
        let wide = "WWWWWWWW"
        let prose = try await renderedSize(narrow)
        let wideProse = try await renderedSize(wide)
        // Negative control: these glyphs must differ in the proportional body face.
        #expect(wideProse.width > prose.width)
        for fence in ["`", "```\n"] {
            let closing = fence == "`" ? "`" : "\n```"
            let narrowCode = try await renderedSize(fence + narrow + closing)
            let wideCode = try await renderedSize(fence + wide + closing)
            #expect(abs(narrowCode.width - wideCode.width) < 1)
        }
        let accessible = try await renderedSize(narrow, category: .accessibility5)
        #expect(accessible.width > prose.width)
        #expect(accessible.height > prose.height)
    }

    @MainActor
    private func renderedSize(_ text: String, category: DynamicTypeSize = .large) async throws -> CGSize {
        var measured = CGSize.zero
        let view = MarkdownTextView(text: text)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
            .environment(\.dynamicTypeSize, category)
        return try await SyntheticBadgeHost.render(view, width: 900, height: 500) { _, _ in
            #expect(measured.width > 0)
            #expect(measured.height > 0)
            return measured
        }
    }
}
