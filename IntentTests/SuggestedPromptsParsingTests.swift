import Foundation
@testable import Intent
import Testing

struct SuggestedPromptsTests {
    @Test func parsesPlainPrompts() {
        let text = "Done!\n<!-- suggested-prompts\nRun the tests\nShip it\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests", "Ship it"])
    }

    @Test func stripsLabelAndDelayPrefixes() {
        let text = "<!-- suggested-prompts\nShort label|Full prompt text\ndelay:60|Check deployment\nLabel|delay:30|Check build\nDELAY:120|Check CI\n-->"
        #expect(SuggestedPrompts.parse(text) == [
            "Full prompt text",
            "Check deployment",
            "Check build",
            "Check CI"
        ])
    }

    @Test func dropsPromptEmptyAfterPrefixStripping() {
        let text = "<!-- suggested-prompts\ndelay:60|\nValid prompt\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Valid prompt"])
    }

    @Test func lengthLimitAppliesAfterPrefixStripping() {
        let label = String(repeating: "L", count: SuggestedPrompts.maxPromptLength)
        let text = "<!-- suggested-prompts\n\(label)|Short prompt\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Short prompt"])
    }

    @Test func doesNotStripNonAsciiDigitDelayPrefix() {
        let text = "<!-- suggested-prompts\nLabel|delay:٦٠|Check build\n-->"
        #expect(SuggestedPrompts.parse(text) == ["delay:٦٠|Check build"])
    }

    @Test func trimsWhitespaceAndSkipsBlankLines() {
        let text = "<!-- suggested-prompts\n  Spaced prompt  \n\n\nSecond\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Spaced prompt", "Second"])
    }

    @Test func toleratesWhitespaceAroundOpenerAndCloser() {
        let text = "<!--   suggested-prompts   \nA prompt\n   -->   "
        #expect(SuggestedPrompts.parse(text) == ["A prompt"])
    }

    @Test func trailingCloserWithRemainderClosesBlock() {
        let text = """
        Done!
        <!-- suggested-prompts
        Run the tests
        Ship it
        Leave rewrite parked for now. -->
        """
        #expect(SuggestedPrompts.parse(text) == [
            "Run the tests",
            "Ship it",
            "Leave rewrite parked for now."
        ])
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func trailingCloserBodyShapedRemainderStripsButYieldsNoPrompts() {
        let text = "Done!\n<!-- suggested-prompts\n## Heading -->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func openerShapedTrailingCloserDoesNotCloseBlock() {
        let text = """
        <!-- suggested-prompts
        Response text that must survive
        <!-- suggested-prompts -->
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    @Test func ignoresOpenerInsideFencedCodeRegion() {
        let text = """
        Here is the convention:

        ```markdown
        <!-- suggested-prompts
        Not a real prompt
        -->
        ```
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func ignoresOpenerInsideTildeFencedRegion() {
        let text = "~~~\n<!-- suggested-prompts\nNope\n-->\n~~~"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func unclosedOpenerFollowedByMermaidArrowYieldsNoPrompts() {
        let text = """
        <!-- suggested-prompts
        ```mermaid
        flowchart LR
          A --> B
        ```
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func embeddedArrowDoesNotCloseBlock() {
        let text = "<!-- suggested-prompts\nStep A --> Step B\n"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func unclosedOpenerYieldsNoPrompts() {
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\nRun tests").isEmpty)
    }

    @Test func openerNotAtLineEndIsNotABlock() {
        let text = "<!-- suggested-prompts Run tests -->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func unclosedOpenerDoesNotSwallowLaterBlock() {
        let text = """
        <!-- suggested-prompts
        A truncated example that is never closed
        <!-- suggested-prompts
        Run the tests
        -->
        """
        #expect(SuggestedPrompts.parse(text) == ["Run the tests"])
        #expect(SuggestedPrompts.stripBlocks(from: text) == """
        <!-- suggested-prompts
        A truncated example that is never closed
        """)
    }

    @Test func toleratesCRLFLineEndings() {
        let text = "Done!\r\n<!-- suggested-prompts\r\nRun the tests\r\n-->\r\n"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests"])
    }
}

extension SuggestedPromptsTests {
    @Test func mismatchedFenceCharDoesNotCloseFence() {
        let text = """
        ```markdown
        ~~~
        <!-- suggested-prompts
        Quoted example
        -->
        ```
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func infoStringedLineInsideFenceDoesNotCloseFence() {
        let text = """
        ~~~
        ```swift
        <!-- suggested-prompts
        Quoted example
        -->
        ~~~
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func deeplyIndentedFenceMarkerDoesNotOpenFence() {
        let text = "    ```\n<!-- suggested-prompts\nRun the tests\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests"])
    }

    @Test func rejectsBlockContainingHeading() {
        let text = "<!-- suggested-prompts\n## Summary\nRun tests\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func rejectsBlockContainingTableRow() {
        let text = "<!-- suggested-prompts\n| Col | Col |\nRun tests\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func rejectsBlockContainingFenceMarker() {
        let text = "<!-- suggested-prompts\nRun tests\n```swift\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func rejectsEmptyBlock() {
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\n\n-->").isEmpty)
    }

    @Test func lastWellFormedBlockWins() {
        let text = """
        <!-- suggested-prompts
        First block
        -->
        More text
        <!-- suggested-prompts
        Second block
        -->
        """
        #expect(SuggestedPrompts.parse(text) == ["Second block"])
    }

    @Test func gateRejectedLastBlockYieldsNoPromptsEvenWithEarlierValidBlock() {
        let text = """
        <!-- suggested-prompts
        Earlier prompt
        -->
        <!-- suggested-prompts
        ## Heading
        -->
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func lastWellFormedBlockWinsOverQuotedExample() {
        let text = """
        ```
        <!-- suggested-prompts
        Quoted example
        -->
        ```
        <!-- suggested-prompts
        Real prompt
        -->
        """
        #expect(SuggestedPrompts.parse(text) == ["Real prompt"])
    }

    @Test func capsAtFourPrompts() {
        let lines = (1...10).map { "Prompt \($0)" }.joined(separator: "\n")
        let prompts = SuggestedPrompts.parse("<!-- suggested-prompts\n\(lines)\n-->")
        #expect(prompts.count == SuggestedPrompts.maxPrompts)
        #expect(prompts == ["Prompt 1", "Prompt 2", "Prompt 3", "Prompt 4"])
    }

    @Test func allInvalidLinesYieldNoPromptsButBlockStillStrips() {
        let long = String(repeating: "x", count: SuggestedPrompts.maxPromptLength + 1)
        let text = "Done!\n<!-- suggested-prompts\n\(long)\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func dropsOverlongPrompts() {
        let long = String(repeating: "x", count: SuggestedPrompts.maxPromptLength + 1)
        let prompts = SuggestedPrompts.parse("<!-- suggested-prompts\n\(long)\nShort\n-->")
        #expect(prompts == ["Short"])
    }

    @Test func keepsPromptAtExactLengthLimit() {
        let atLimit = String(repeating: "x", count: SuggestedPrompts.maxPromptLength)
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\n\(atLimit)\n-->") == [atLimit])
    }

    @Test func stripsWellFormedBlock() {
        let text = "Done!\n<!-- suggested-prompts\nRun tests\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func stripsAllWellFormedBlocks() {
        let text = "A\n<!-- suggested-prompts\nOne\n-->\nB\n<!-- suggested-prompts\nTwo\n-->\nC"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "A\nB\nC")
    }

    @Test func stripKeepsTextBeforeInlineOpener() {
        let text = "Trailing text <!-- suggested-prompts\nRun tests\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Trailing text ")
    }

    @Test func stripLeavesUnclosedOpenerAndBodyIntact() {
        let text = "<!-- suggested-prompts\nA --> B\nMore body"
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    @Test func stripLeavesFencedBlockIntact() {
        let text = "```\n<!-- suggested-prompts\nExample\n-->\n```"
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    @Test func stripsBodyTextShapedBlock() {
        let text = "Done!\n<!-- suggested-prompts\n## Heading\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    private func texts(_ blocks: [ContentBlock]) -> [String?] {
        blocks.map { $0.type == .text ? $0.resolvedText : nil }
    }

    @Test func contentBlocksSpanningBoundaryStripAndParse() {
        let blocks = [
            ContentBlock(type: .text, text: "Done!\n<!-- suggested-prompts\nRun the te"),
            ContentBlock(type: .text, text: "sts\nShip it\n-->")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests", "Ship it"])
        #expect(texts(result.contentBlocks) == ["Done!\n", ""])
    }

    @Test func contentBlocksMidLineSplitReassembles() {
        let blocks = [
            ContentBlock(type: .text, text: "Done!\n<!-- suggested-"),
            ContentBlock(type: .text, text: "prompts\nRun the tests\n-->")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests"])
        #expect(texts(result.contentBlocks) == ["Done!\n", ""])
    }

    @Test func contentBlocksSingleBlockMatchesStringParse() {
        let text = "Done!\n<!-- suggested-prompts\nRun tests\n-->\nTail"
        let result = SuggestedPrompts.parse(contentBlocks: [ContentBlock(type: .text, text: text)])
        #expect(result.prompts == SuggestedPrompts.parse(text))
        #expect(texts(result.contentBlocks) == [SuggestedPrompts.stripBlocks(from: text)])
        #expect(texts(result.contentBlocks) == ["Done!\nTail"])
    }

    @Test func contentBlocksNonTextBlocksPassThroughUntouched() {
        let blocks = [
            ContentBlock(type: .text, text: "Done!\n<!-- suggested-prompts\n"),
            ContentBlock(type: .code, text: "let x = 1"),
            ContentBlock(type: .text, text: "Run the tests\n-->")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests"])
        #expect(result.contentBlocks[1].resolvedText == "let x = 1")
        #expect(texts(result.contentBlocks) == ["Done!\n", nil, ""])
    }

    @Test func contentBlocksUnclosedOpenerLeavesBlocksUntouched() {
        let blocks = [
            ContentBlock(type: .text, text: "Done!\n<!-- suggested-prompts"),
            ContentBlock(type: .text, text: "\nRun the tests")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts.isEmpty)
        #expect(texts(result.contentBlocks) == ["Done!\n<!-- suggested-prompts", "\nRun the tests"])
    }

    @Test func contentBlocksMultipleBlocksAllStripLastSuppliesPrompts() {
        let blocks = [
            ContentBlock(type: .text, text: "A\n<!-- suggested-prompts\nOne\n-->\nB\n<!-- suggested-"),
            ContentBlock(type: .text, text: "prompts\nTwo\n-->\nC")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Two"])
        #expect(texts(result.contentBlocks) == ["A\nB\n", "C"])
    }

    @Test func contentBlocksLegacyContentFieldRoundTrips() throws {
        let json = Data("""
        {"type": "text", "content": "Done!\\n<!-- suggested-prompts\\nRun the te"}
        """.utf8)
        let legacy = try JSONDecoder().decode(ContentBlock.self, from: json)
        let blocks = [legacy, ContentBlock(type: .text, text: "sts\n-->")]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests"])
        #expect(texts(result.contentBlocks) == ["Done!\n", ""])
    }

    @Test func contentBlocksEmojiBeforeBoundaryKeepsOffsetsAligned() {
        let blocks = [
            ContentBlock(type: .text, text: "Done 🎉!\n<!-- suggested-prompts\nRun the te"),
            ContentBlock(type: .text, text: "sts\n-->")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests"])
        #expect(texts(result.contentBlocks) == ["Done 🎉!\n", ""])
    }
}
