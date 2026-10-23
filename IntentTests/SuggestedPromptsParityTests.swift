import Foundation
@testable import Intent
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

    @Test func visibleTextKeepsNonLinkBracketsLiteral() {
        #expect(SuggestedPromptLinks.visibleText("See [docs](https://a.test) now") == "See docs now")
        #expect(SuggestedPromptLinks.visibleText("![img](https://a.test/x.png)") == "![img](https://a.test/x.png)")
        #expect(SuggestedPromptLinks.visibleText("[x](javascript:alert(1))") == "[x](javascript:alert(1))")
        #expect(SuggestedPromptLinks.textAfterLabel("no pipe here") == nil)
    }
}
