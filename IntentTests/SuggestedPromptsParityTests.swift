import Foundation
@testable import Intent
import SwiftUI
import Testing

/// Behaviors the shared suggested-prompts cases (monorepo
/// `docs/protocol/suggested-prompts.md`) showed iOS getting wrong.
struct SuggestedPromptsParityTests {
    @Test(arguments: [
        "Intro\n<!-- suggested-prompts\nSome text the agent wrote\n```diff\n-->\n```\nOutro",
        "<!-- suggested-prompts\n\n```markdown\n-->\n```\n\nBody text that must survive.",
        "<!-- suggested-prompts\nRun tests\n```mermaid\nflowchart LR\n  A -->\n```",
        "Use this format:\n<!-- suggested-prompts\n```markdown\n<!-- suggested-prompts\nExample prompt\n-->\n```\nDone."
    ])
    func fencedCloserNeverClosesAnOpenBlock(text: String) {
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func blockClosesAfterAFencedRegion() {
        // The fenced lines stay in the body (body-shaped, so no chips), and the
        // later standalone closer still ends the block.
        let text = "Done.\n<!-- suggested-prompts\n```\n-->\n```\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done.")
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func lengthLimitCountsVisibleLinkText() {
        let url = "https://github.com/intent-hq/intent/pull/5034"
        let links = (5030..<5035).map { "[#\($0)](\(url))" }.joined(separator: ", ")
        let prompt = "Approve \(links) and merge them."
        #expect(prompt.utf16.count > SuggestedPrompts.maxPromptLength)
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\n\(prompt)\n-->") == [prompt])

        let overLong = "[#1](https://a.test/1) " + String(repeating: "x", count: 200)
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\n\(overLong)\nRun tests\n-->") == ["Run tests"])
    }

    @Test func labelPipeIgnoresPipesInsideLinks() {
        let labelPipe = "Review [CI | results](https://a.test)"
        let destinationPipe = "Review [results](https://a.test?q=a|b)"
        let text = [
            "<!-- suggested-prompts", labelPipe, destinationPipe, "Label|\(labelPipe)",
            "[x|y](https://a.test)|delay:30|\(destinationPipe)", "-->"
        ].joined(separator: "\n")
        #expect(SuggestedPrompts.parse(text) == [labelPipe, destinationPipe, labelPipe, destinationPipe])
    }

    @Test func trimsDecodedByteOrderMarkLikeTheDesktop() {
        // JS trim() removes U+FEFF; Foundation's whitespace set does not.
        let text = "&lt;!-- suggested-prompts\n&#xFEFF;\nok\n--&gt;"
        #expect(SuggestedPrompts.parse(text) == ["ok"])
    }

    @Test func delayPrefixNeverSpansADecodedLineBreak() {
        // The desktop's `^delay:(\d+)\|(.*)$` fails when `.` meets a newline.
        let text = "&lt;!-- suggested-prompts\nL|delay:5|run&#10;tests\n--&gt;"
        #expect(SuggestedPrompts.parse(text) == ["delay:5|run\ntests"])
    }

    @Test func decodingStaysLinearWithoutNearbySemicolons() {
        let line = String(repeating: "&", count: 50_000) + ";"
        let text = "&lt;!-- suggested-prompts\n\(line)\n--&gt;"
        let start = Date()
        _ = SuggestedPrompts.parse(text)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func visibleTextKeepsNonLinkBracketsLiteral() {
        #expect(SuggestedPromptLinks.visibleText("See [docs](https://a.test) now") == "See docs now")
        #expect(SuggestedPromptLinks.visibleText("![img](https://a.test/x.png)") == "![img](https://a.test/x.png)")
        #expect(SuggestedPromptLinks.visibleText("[x](javascript:alert(1))") == "[x](javascript:alert(1))")
        #expect(SuggestedPromptLinks.textAfterLabel("no pipe here") == nil)
    }

    @Test func displayTextUnderlinesLinksWithoutLinkAttributes() {
        let text = SuggestedPromptLinks.displayText("Merge [PR #3770](https://a.test/pr/3770) **now**.")
        #expect(String(text.characters) == "Merge PR #3770 now.")
        let link = text.runs.first { String(text[$0.range].characters) == "PR #3770" }
        #expect(link?.underlineStyle == .single)
        #expect(text.runs.allSatisfy { $0.link == nil })
        let bold = text.runs.first { String(text[$0.range].characters) == "now" }
        #expect(bold?.inlinePresentationIntent == .stronglyEmphasized)
    }
}
