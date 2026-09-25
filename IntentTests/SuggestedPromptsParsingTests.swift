import Foundation
@testable import Intent
import Testing

// MARK: - SuggestedPrompts Tests

struct SuggestedPromptsTests {
    // MARK: - Valid formats

    @Test func parsesPlainPrompts() {
        let text = "Done!\n<!-- suggested-prompts\nRun the tests\nShip it\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests", "Ship it"])
    }

    @Test func stripsLabelAndDelayPrefixes() {
        // Mirrors the desktop's `Label|` / `delay:N|` stripping so both
        // clients surface identical chip text.
        let text = "<!-- suggested-prompts\nShort label|Full prompt text\ndelay:60|Check deployment\nLabel|delay:30|Check build\nDELAY:120|Check CI\n-->"
        #expect(SuggestedPrompts.parse(text) == [
            "Full prompt text",
            "Check deployment",
            "Check build",
            "Check CI"
        ])
    }

    @Test func dropsPromptEmptyAfterPrefixStripping() {
        // `delay:60|` with no remainder is an invalid line: dropped, the
        // valid siblings survive.
        let text = "<!-- suggested-prompts\ndelay:60|\nValid prompt\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Valid prompt"])
    }

    @Test func lengthLimitAppliesAfterPrefixStripping() {
        // A raw line over 200 UTF-16 units whose prompt fits after `Label|`
        // stripping is kept: the length check runs post-strip, like desktop.
        let label = String(repeating: "L", count: SuggestedPrompts.maxPromptLength)
        let text = "<!-- suggested-prompts\n\(label)|Short prompt\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Short prompt"])
    }

    @Test func doesNotStripNonAsciiDigitDelayPrefix() {
        // ICU `\d` would match Unicode digits; the desktop's regex is
        // ASCII-only, so a non-ASCII delay prefix stays part of the prompt.
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
        // The raw closer-bearing line always matches the Mermaid-edge pattern,
        // so this also proves the body-text gate runs on the remainder.
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
        // `<!-- suggested-prompts -->` under an unclosed opener must stay
        // inert: closing there would let stripBlocks delete the body text
        // captured by the outer opener.
        let text = """
        <!-- suggested-prompts
        Response text that must survive
        <!-- suggested-prompts -->
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    // MARK: - Malformed blocks

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
        // A second opener means the first was never closed; the scan must
        // resume there instead of consuming the inner, well-formed block.
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
    // MARK: - Fence bookkeeping

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
        // Four spaces is an indented code block, not a fence, so it must not
        // flip fence state and hide the real block that follows.
        let text = "    ```\n<!-- suggested-prompts\nRun the tests\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests"])
    }

    // MARK: - Body-text rejection

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

    // MARK: - Last block wins

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
        // The gate applies only to the last well-formed block; an earlier block
        // must not resurface stale prompts.
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

    // MARK: - Caps

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

    // MARK: - Stripping

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
        // A standalone `-->` closer makes the block unambiguously comment
        // delimited, so removing it can never remove body text — even though
        // it contributes no prompts.
        let text = "Done!\n<!-- suggested-prompts\n## Heading\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    // MARK: - Message-level scan (parse(contentBlocks:))

    private func texts(_ blocks: [ContentBlock]) -> [String?] {
        blocks.map { $0.type == .text ? $0.resolvedText : nil }
    }

    @Test func contentBlocksSpanningBoundaryStripAndParse() {
        // Opener in one block, body + closer in the next: per-block stripping
        // sees no well-formed block in either, but the message-level scan
        // (empty join, like the desktop) reassembles it
        // (intent-hq/intent#3936).
        let blocks = [
            ContentBlock(type: .text, text: "Done!\n<!-- suggested-prompts\nRun the te"),
            ContentBlock(type: .text, text: "sts\nShip it\n-->")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests", "Ship it"])
        #expect(texts(result.contentBlocks) == ["Done!\n", ""])
    }

    @Test func contentBlocksMidLineSplitReassembles() {
        // The empty-separator join fuses a mid-line split back together, so
        // even the opener token itself can straddle the boundary.
        let blocks = [
            ContentBlock(type: .text, text: "Done!\n<!-- suggested-"),
            ContentBlock(type: .text, text: "prompts\nRun the tests\n-->")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests"])
        #expect(texts(result.contentBlocks) == ["Done!\n", ""])
    }

    @Test func contentBlocksSingleBlockMatchesStringParse() {
        // The range consumes the closer line's newline, so the result matches
        // the line-based stripBlocks(from:) exactly — no paragraph break is
        // introduced where the block used to be.
        let text = "Done!\n<!-- suggested-prompts\nRun tests\n-->\nTail"
        let result = SuggestedPrompts.parse(contentBlocks: [ContentBlock(type: .text, text: text)])
        #expect(result.prompts == SuggestedPrompts.parse(text))
        #expect(texts(result.contentBlocks) == [SuggestedPrompts.stripBlocks(from: text)])
        #expect(texts(result.contentBlocks) == ["Done!\nTail"])
    }

    @Test func contentBlocksNonTextBlocksPassThroughUntouched() {
        // Non-text blocks neither join into the scan nor get modified; a code
        // block between the opener and closer does not interrupt the text
        // stream (same as the desktop's text-only join).
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
        // Blocks decoded from the legacy `content` alias still join into the
        // scan and carry the cleaned text back out via `resolvedText`.
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
        // Multi-byte scalars before the boundary must not skew the range
        // mapping — offsets are UTF-16-unit based.
        let blocks = [
            ContentBlock(type: .text, text: "Done 🎉!\n<!-- suggested-prompts\nRun the te"),
            ContentBlock(type: .text, text: "sts\n-->")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run the tests"])
        #expect(texts(result.contentBlocks) == ["Done 🎉!\n", ""])
    }
}
