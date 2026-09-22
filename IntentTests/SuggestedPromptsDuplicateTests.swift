import Foundation
@testable import Intent
import Testing

extension SuggestedPromptsTests {
    @Test func emptyRepeatedOpenersStripWithClosedPromptsAfterImage() {
        let body = "Before 🎉\n![Preview](workspace-asset://ws/image.png)\nAfter\n"
        let text = body + "<!-- suggested-prompts\n\n<!-- suggested-prompts\nRecording|Show the recording screen.\nShow the mobile layout.\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Show the recording screen.", "Show the mobile layout."])
        #expect(SuggestedPrompts.stripBlocks(from: text) == String(body.dropLast()))
        let result = SuggestedPrompts.parse(contentBlocks: [ContentBlock(type: .text, text: text)])
        #expect(result.prompts == SuggestedPrompts.parse(text))
        #expect(result.contentBlocks.first?.resolvedText == body)
    }

    @Test(arguments: ["\n", "\r\n"])
    func repeatedOpenersReassembleAtEveryTextBoundary(newline: String) {
        let body = "![Preview](workspace-asset://ws/image.png)\n"
        let text = body + [
            "<!-- suggested-prompts", "\t", "<!-- suggested-prompts", "<!-- suggested-prompts",
            "Show the mobile layout. -->", "Tail"
        ].joined(separator: newline)
        for boundary in text.indices {
            let blocks = [
                ContentBlock(type: .text, text: String(text[..<boundary])),
                ContentBlock(type: .code, text: "unchanged"),
                ContentBlock(type: .text, text: String(text[boundary...]))
            ]
            let result = SuggestedPrompts.parse(contentBlocks: blocks)
            #expect(result.prompts == ["Show the mobile layout."])
            #expect(result.contentBlocks.filter { $0.type == .text }.compactMap(\.resolvedText).joined() == body + "Tail")
            #expect(result.contentBlocks[1] == blocks[1])
        }
    }

    @Test func unclosedRepeatedOpenersAndPartialTokensStayIntactUntilClosed() {
        let prefix = "Before\n<!-- suggested-prompts\n"
        for suffix in ["<!-- suggested-", "<!-- suggested-prompts", "<!-- suggested-prompts\nRun tests\n--"] {
            let text = prefix + suffix
            #expect(SuggestedPrompts.stripBlocks(from: text) == text)
            #expect(SuggestedPrompts.parse(text).isEmpty)
        }
        #expect(SuggestedPrompts.stripBlocks(from: prefix + "<!-- suggested-prompts\nRun tests\n-->") == "Before")
    }

    @Test(arguments: ["prose", "## Heading", "A --> B"])
    func repeatedOpenerDoesNotEraseInterveningBody(body: String) {
        let prefix = "<!-- suggested-prompts\n\(body)\n"
        let text = prefix + "<!-- suggested-prompts\nRun tests\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Run tests"])
        #expect(SuggestedPrompts.stripBlocks(from: text) == String(prefix.dropLast()))
    }

    @Test(arguments: ["```", "~~~"])
    func repeatedOpenersInsideFencesRemainExamples(fence: String) {
        let example = "\(fence)\n<!-- suggested-prompts\n<!-- suggested-prompts\nExample\n-->\n\(fence)"
        let text = example + "\n<!-- suggested-prompts\nReal prompt\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Real prompt"])
        #expect(SuggestedPrompts.stripBlocks(from: text) == example)
    }

    @Test func textBeforeRepeatedOpenerSurvives() {
        let text = "<!-- suggested-prompts\nKeep this <!-- suggested-prompts\nRun tests\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "<!-- suggested-prompts\nKeep this ")
        #expect(SuggestedPrompts.parse(text) == ["Run tests"])
    }
}
