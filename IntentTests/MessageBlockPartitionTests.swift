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
