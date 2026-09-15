import Foundation
@testable import Intent
import Testing

/// User-row block partitioning: text renders first, image attachments render
/// after as a thumbnail row, file attachments last as chips, regardless of
/// block order in the payload.
struct MessageBlockPartitionTests {
    private func textBlock(_ text: String) -> ContentBlock {
        ContentBlock(type: .text, text: text)
    }

    private func imageBlock(_ data: String = "aGk=") -> ContentBlock {
        ContentBlock(type: .image, data: data, mimeType: "image/png")
    }

    private func fileBlock(_ name: String = "a.txt") -> ContentBlock {
        ContentBlock(type: .file, fileName: name, attachmentId: "att-1", size: 3)
    }

    @Test func textThenImagesStaysOrdered() {
        let blocks = [textBlock("hello"), imageBlock("YQ=="), imageBlock("Yg==")]
        let result = MessageView.partitionUserBlocks(blocks)
        #expect(result.text.map(\.text) == ["hello"])
        #expect(result.images.map(\.data) == ["YQ==", "Yg=="])
    }

    @Test func imagesBeforeTextArePartitionedAfter() {
        let blocks = [imageBlock("YQ=="), textBlock("hello")]
        let result = MessageView.partitionUserBlocks(blocks)
        #expect(result.text.map(\.text) == ["hello"])
        #expect(result.images.map(\.data) == ["YQ=="])
    }

    @Test func interleavedBlocksPreserveRelativeOrderWithinKind() {
        let blocks = [
            imageBlock("YQ=="),
            textBlock("one"),
            imageBlock("Yg=="),
            textBlock("two"),
            imageBlock("Yw==")
        ]
        let result = MessageView.partitionUserBlocks(blocks)
        #expect(result.text.map(\.text) == ["one", "two"])
        #expect(result.images.map(\.data) == ["YQ==", "Yg==", "Yw=="])
    }

    @Test func otherBlockTypesAreDropped() {
        let blocks = [
            textBlock("hello"),
            fileBlock(),
            ContentBlock(type: .code, text: "let x = 1"),
            imageBlock()
        ]
        let result = MessageView.partitionUserBlocks(blocks)
        #expect(result.text.count == 1)
        #expect(result.images.count == 1)
        #expect(result.files.count == 1, "file blocks render as chips, not dropped")
    }

    @Test func fileBlocksArePartitionedInOrder() {
        let blocks = [
            fileBlock("b.pdf"),
            textBlock("hello"),
            fileBlock("a.txt")
        ]
        let result = MessageView.partitionUserBlocks(blocks)
        #expect(result.text.map(\.text) == ["hello"])
        #expect(result.files.map(\.fileName) == ["b.pdf", "a.txt"])
    }

    @Test func emptyBlocksYieldEmptyPartitions() {
        let result = MessageView.partitionUserBlocks([])
        #expect(result.text.isEmpty)
        #expect(result.images.isEmpty)
        #expect(result.files.isEmpty)
    }
}

/// Copied-string composition for the whole-message Copy action:
/// `MessageView.plainTextContent` joins text/code blocks, skips
/// tool/thinking/image blocks, strips supervisor tags and wake prefixes,
/// and replaces `@context[...]` tokens with their decoded titles.
struct MessagePlainTextContentTests {
    @Test func joinsTextAndCodeBlocksSkippingOthers() {
        let blocks = [
            ContentBlock(type: .text, text: "intro"),
            ContentBlock(type: .toolUse, name: "read_file"),
            ContentBlock(type: .code, text: "let x = 1"),
            ContentBlock(type: .thinking, text: "hmm"),
            ContentBlock(type: .image, data: "aGk=", mimeType: "image/png"),
            ContentBlock(type: .text, text: "outro")
        ]
        #expect(MessageView.plainTextContent(from: blocks) == "intro\n\nlet x = 1\n\noutro")
    }

    @Test func replacesContextTokensWithTitles() {
        let blocks = [ContentBlock(type: .text, text: "see @context[linear|AU-1|Fix crash] please")]
        #expect(MessageView.plainTextContent(from: blocks) == "see Fix crash please")
    }

    @Test func stripsSupervisorTagsAndDropsEmptiedBlocks() {
        let blocks = [
            ContentBlock(type: .text, text: "<supervisor>internal</supervisor>hello"),
            ContentBlock(type: .text, text: "<supervisor>only internal</supervisor>")
        ]
        #expect(MessageView.plainTextContent(from: blocks) == "hello")
    }

    @Test func stripsHookWakePrefixAndStateNote() {
        let attribution = HookWakeAttribution(
            hookId: "h-1",
            rawName: "CI watcher",
            displayName: "CI watcher",
            reason: "dispatched",
            postWakeState: .retired
        )
        let blocks = [
            ContentBlock(
                type: .text,
                text: "[Background hook \"CI watcher\"] Checks passed.\n\n[This hook has now fired and is retired.]"
            )
        ]
        #expect(MessageView.plainTextContent(from: blocks, hookWake: attribution) == "Checks passed.")
    }

    @Test func stripsPrMonitorWakePrefix() {
        let attribution = PrMonitorWakeAttribution(
            monitorId: "m-1",
            repo: "intent-hq/ios",
            prNumber: 7,
            url: nil
        )
        let blocks = [ContentBlock(type: .text, text: "[PR monitor intent-hq/ios#7] PR was approved.")]
        #expect(MessageView.plainTextContent(from: blocks, prWake: attribution) == "PR was approved.")
    }

    @Test func imageOnlyBlocksYieldEmptyString() {
        let blocks = [ContentBlock(type: .image, data: "aGk=", mimeType: "image/png")]
        #expect(MessageView.plainTextContent(from: blocks).isEmpty)
    }

    // MARK: - User-row copy (mirrors what the row renders)

    @Test func userCopyExcludesCodeAndOtherNonRenderedBlocks() {
        let blocks = [
            ContentBlock(type: .text, text: "hello"),
            ContentBlock(type: .code, text: "let hidden = true"),
            ContentBlock(type: .file, fileName: "a.txt"),
            ContentBlock(type: .image, data: "aGk=", mimeType: "image/png")
        ]
        #expect(MessageView.userCopyText(from: blocks) == "hello")
    }

    @Test func userCopyStripsHookWakePrefix() {
        let attribution = HookWakeAttribution(
            hookId: "h-1",
            rawName: "CI watcher",
            displayName: "CI watcher",
            reason: "dispatched",
            postWakeState: .unreported
        )
        let blocks = [ContentBlock(type: .text, text: "[Background hook \"CI watcher\"] Checks passed.")]
        #expect(MessageView.userCopyText(from: blocks, hookWake: attribution) == "Checks passed.")
    }

    // MARK: - Assistant-row copy (mirrors what the row renders)

    @Test func assistantCopyStripsGroupTagsAndFlattensGroupedText() {
        let blocks = [
            ContentBlock(type: .text, text: "<group:Setup>\nreading files\n</group>\nAll done.")
        ]
        #expect(MessageView.assistantCopyText(from: blocks) == "reading files\n\nAll done.")
    }

    @Test func assistantCopyStripsProtocolBlocksLikeDisplay() {
        let blocks = [
            ContentBlock(type: .text, text: "Answer.\n<!-- suggested-prompts\nNext step\n-->"),
            ContentBlock(type: .text, text: "<agent_digest>internal digest</agent_digest>"),
            ContentBlock(type: .text, text: "<!-- plain comment -->tail")
        ]
        #expect(MessageView.assistantCopyText(from: blocks) == "Answer.\n\ntail")
    }

    @Test func assistantCopyStripsSuggestedPromptsSpanningTextBlocks() {
        // A block well-formed only across text-block boundaries is stripped
        // by the message-level pre-scan, so the copy matches the display
        // (intent-hq/intent#3936).
        let blocks = [
            ContentBlock(type: .text, text: "Answer.\n<!-- suggested-prompts\nRun the te"),
            ContentBlock(type: .text, text: "sts\n-->\n"),
            ContentBlock(type: .text, text: "tail")
        ]
        #expect(MessageView.assistantCopyText(from: blocks) == "Answer.\n\ntail")
    }

    @Test func assistantCopyKeepsCodeAndSkipsToolBlocks() {
        let blocks = [
            ContentBlock(type: .text, text: "intro"),
            ContentBlock(type: .toolUse, name: "read_file"),
            ContentBlock(type: .code, text: "let x = 1"),
            ContentBlock(type: .thinking, text: "hmm")
        ]
        #expect(MessageView.assistantCopyText(from: blocks) == "intro\n\nlet x = 1")
    }
}

/// One-line preview shown in the collapsed agent-to-agent disclosure header:
/// `MessageView.agentMessagePreview` renders the row's copy text with all
/// whitespace runs (including newlines) collapsed to single spaces.
struct AgentMessagePreviewTests {
    @Test func collapsesNewlinesAndWhitespaceRunsToOneLine() {
        let blocks = [
            ContentBlock(
                type: .text,
                text: "# Task Title\n\nLong kickoff body   with\tspacing.\n- item one\n- item two"
            )
        ]
        #expect(MessageView.agentMessagePreview(from: blocks)
            == "# Task Title Long kickoff body with spacing. - item one - item two")
    }

    @Test func joinsMultipleTextBlocksWithSingleSpaces() {
        let blocks = [
            ContentBlock(type: .text, text: "first block"),
            ContentBlock(type: .text, text: "second block")
        ]
        #expect(MessageView.agentMessagePreview(from: blocks) == "first block second block")
    }

    @Test func stripsSupervisorTagsAndReplacesContextTokens() {
        let blocks = [
            ContentBlock(
                type: .text,
                text: "<supervisor>internal</supervisor>see @context[linear|AU-1|Fix crash] please"
            )
        ]
        #expect(MessageView.agentMessagePreview(from: blocks) == "see Fix crash please")
    }

    @Test func nonTextBlocksYieldEmptyPreview() {
        let blocks = [
            ContentBlock(type: .image, data: "aGk=", mimeType: "image/png"),
            ContentBlock(type: .code, text: "let hidden = true")
        ]
        #expect(MessageView.agentMessagePreview(from: blocks).isEmpty)
    }

    @Test func emptyBlocksYieldEmptyPreview() {
        #expect(MessageView.agentMessagePreview(from: []).isEmpty)
    }
}
