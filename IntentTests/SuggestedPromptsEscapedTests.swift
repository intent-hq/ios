import Foundation
@testable import Intent
import Testing

/// HTML-escaped blocks: history replayed to a fresh provider session is
/// XML-escaped, and a model can copy `&lt;!-- suggested-prompts` ... `--&gt;`
/// from it into its own reply. Mirrors the desktop's handling
/// (cloudlands-fe#3633): the escaped spelling is a block too, closes only on
/// the escaped closer, and its prompt lines are entity-decoded once.
struct SuggestedPromptsEscapedTests {
    /// Verbatim tail of the reply that leaked raw markup after a quota failover.
    private let failoverReply = """
        Report back when the PR is ready to merge.

        &lt;!-- suggested-prompts
        Run the full sizing report tomorrow and then start the job-size declarations.
        Raise Type Check &amp; Lint's timeout to 45 minutes.
        What are WarpBuild's per-minute prices for 8x and 16x?
        --&gt;
        """

    @Test func stripsEscapedBlockAndDecodesPrompts() {
        #expect(SuggestedPrompts.stripBlocks(from: failoverReply) == "Report back when the PR is ready to merge.\n")
        #expect(SuggestedPrompts.parse(failoverReply) == [
            "Run the full sizing report tomorrow and then start the job-size declarations.",
            "Raise Type Check & Lint's timeout to 45 minutes.",
            "What are WarpBuild's per-minute prices for 8x and 16x?"
        ])
    }

    @Test func stripsEscapedBlockFromContentBlocks() {
        let blocks = [
            ContentBlock(type: .text, text: "Done.\n\n&lt;!-- sugg"),
            ContentBlock(type: .text, text: "ested-prompts\nRun Type Check &amp; Lint.\n--&gt;")
        ]
        let result = SuggestedPrompts.parse(contentBlocks: blocks)
        #expect(result.prompts == ["Run Type Check & Lint."])
        #expect(result.contentBlocks.compactMap(\.resolvedText).joined() == "Done.\n\n")
    }

    @Test func acceptsFusedEscapedCloser() {
        let text = "Done.\n\n&lt;!-- suggested-prompts\nRun the tests.\nOpen the PR. --&gt;"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests.", "Open the PR."])
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done.\n")
    }

    @Test func decodesNamedAndNumericReferencesOnce() {
        let named = "&lt;!-- suggested-prompts\nRename &quot;a&lt;b&gt;&quot; to &#39;c&#39;.\n--&gt;"
        #expect(SuggestedPrompts.parse(named) == ["Rename \"a<b>\" to 'c'."])
        let numeric = "&lt;!-- suggested-prompts\nRename &#34;foo&#34; in src&#x2F;lib.\n--&gt;"
        #expect(SuggestedPrompts.parse(numeric) == ["Rename \"foo\" in src/lib."])
        let double = "&lt;!-- suggested-prompts\nExplain &amp;lt;b&amp;gt; tags.\n--&gt;"
        #expect(SuggestedPrompts.parse(double) == ["Explain &lt;b&gt; tags."])
    }

    @Test func keepsInvalidNumericReferencesLiteral() {
        let text = "&lt;!-- suggested-prompts\nKeep &#xD800; and &#55296; and &#x110000; and &#0;.\nShip &#x1F680; now.\n--&gt;"
        #expect(SuggestedPrompts.parse(text) == [
            "Keep &#xD800; and &#55296; and &#x110000; and &#0;.",
            "Ship 🚀 now."
        ])
    }

    @Test func doesNotDecodeEntitiesInLiteralBlock() {
        let text = "<!-- suggested-prompts\nExplain what &amp; means in HTML.\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Explain what &amp; means in HTML."])
    }

    @Test func gatesEscapedBodyShapedLines() {
        let text = "Done.\n\n&lt;!-- suggested-prompts\nA --&gt; B\n--&gt;"
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done.\n")
    }

    @Test func leavesFencedEscapedBlockUntouched() {
        let text = "```\n&lt;!-- suggested-prompts\nRun tests.\n--&gt;\n```"
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func leavesInlineEscapedOpenerUntouched() {
        let text = "Write &lt;!-- suggested-prompts at the end of a line to start a block."
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    @Test func spellingsDoNotCloseEachOther() {
        let escapedOpener = "Done.\n\n&lt;!-- suggested-prompts\nRun the tests.\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: escapedOpener) == escapedOpener)
        #expect(SuggestedPrompts.parse(escapedOpener).isEmpty)

        let literalOpener = "Done.\n\n<!-- suggested-prompts\nExplain the escaped closer.\n--&gt;\nRun tests\n-->"
        #expect(SuggestedPrompts.parse(literalOpener) == ["Explain the escaped closer.", "--&gt;", "Run tests"])
        #expect(SuggestedPrompts.stripBlocks(from: literalOpener) == "Done.\n")
    }
}
