import Foundation
import Testing
@testable import Intent

/// User-row block partitioning: text renders first, image attachments render
/// after as a thumbnail row, regardless of block order in the payload.
struct MessageBlockPartitionTests {
    private func textBlock(_ text: String) -> ContentBlock {
        ContentBlock(type: .text, text: text)
    }

    private func imageBlock(_ data: String = "aGk=") -> ContentBlock {
        ContentBlock(type: .image, data: data, mimeType: "image/png")
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
            imageBlock("YQ=="), textBlock("one"), imageBlock("Yg=="),
            textBlock("two"), imageBlock("Yw=="),
        ]
        let result = MessageView.partitionUserBlocks(blocks)
        #expect(result.text.map(\.text) == ["one", "two"])
        #expect(result.images.map(\.data) == ["YQ==", "Yg==", "Yw=="])
    }

    @Test func otherBlockTypesAreDropped() {
        let blocks = [
            textBlock("hello"),
            ContentBlock(type: .file, fileName: "a.txt"),
            ContentBlock(type: .code, text: "let x = 1"),
            imageBlock(),
        ]
        let result = MessageView.partitionUserBlocks(blocks)
        #expect(result.text.count == 1)
        #expect(result.images.count == 1)
    }

    @Test func emptyBlocksYieldEmptyPartitions() {
        let result = MessageView.partitionUserBlocks([])
        #expect(result.text.isEmpty)
        #expect(result.images.isEmpty)
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
            ContentBlock(type: .text, text: "outro"),
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
            ContentBlock(type: .text, text: "<supervisor>only internal</supervisor>"),
        ]
        #expect(MessageView.plainTextContent(from: blocks) == "hello")
    }

    @Test func stripsHookWakePrefixAndStateNote() {
        let attribution = HookWakeAttribution(
            hookId: "h-1", rawName: "CI watcher", displayName: "CI watcher",
            reason: "dispatched", hookStillActive: false)
        let blocks = [ContentBlock(
            type: .text,
            text: "[Background hook \"CI watcher\"] Checks passed.\n\n[This hook has now fired and is retired.]")]
        #expect(MessageView.plainTextContent(from: blocks, hookWake: attribution) == "Checks passed.")
    }

    @Test func stripsPrMonitorWakePrefix() {
        let attribution = PrMonitorWakeAttribution(
            monitorId: "m-1", repo: "intent-hq/ios", prNumber: 7, url: nil)
        let blocks = [ContentBlock(type: .text, text: "[PR monitor intent-hq/ios#7] PR was approved.")]
        #expect(MessageView.plainTextContent(from: blocks, prWake: attribution) == "PR was approved.")
    }

    @Test func imageOnlyBlocksYieldEmptyString() {
        let blocks = [ContentBlock(type: .image, data: "aGk=", mimeType: "image/png")]
        #expect(MessageView.plainTextContent(from: blocks).isEmpty)
    }
}
