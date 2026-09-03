import Foundation
import Testing
@testable import Intent

/// Deterministic identities for parsed render blocks: `groupContentBlocks`
/// derives synthetic-segment and group ids from their source block (block id
/// + segment index; group: block id + per-block ordinal + name), so
/// re-parsing identical input yields identical ids and streaming deltas do
/// not change the identity — and thus tear down the view State — of
/// already-rendered segments and groups.
struct RenderBlockIdentityTests {
    private func textBlock(_ id: String, _ text: String) -> ContentBlock {
        ContentBlock(id: id, type: .text, text: text)
    }

    private func ids(_ blocks: [ContentBlock], isStreaming: Bool = false) -> [String] {
        MessageView.groupContentBlocks(blocks, isStreaming: isStreaming).map(\.id)
    }

    @Test func reparsingIdenticalInputYieldsIdenticalIds() {
        let blocks = [
            textBlock("b1", "intro\n<group:Setup>\nreading\n</group>\nmiddle\n<group:Work>\ndoing\n</group>\ntail"),
            ContentBlock(id: "b2", type: .toolUse, name: "read_file"),
            textBlock("b3", "outro"),
        ]
        let first = ids(blocks)
        let second = ids(blocks)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test func distinctSegmentsAndGroupsGetDistinctIds() {
        let blocks = [
            textBlock("b1", "one\n<group:A>\ninside\n</group>\ntwo\n<group:A>\nagain\n</group>\nthree"),
        ]
        let result = ids(blocks)
        #expect(result.count == 5)
        #expect(Set(result).count == result.count)
    }

    @Test func sameTextInDifferentSourceBlocksGetsDistinctIds() {
        let blocks = [
            textBlock("b1", "<group:A>\nx\n</group>\ntail"),
            textBlock("b2", "<group:A>\nx\n</group>\ntail"),
        ]
        let result = ids(blocks)
        #expect(Set(result).count == result.count)
    }

    @Test func passthroughBlocksKeepTheirOriginalId() {
        let blocks = [
            textBlock("b1", "no tags here"),
            ContentBlock(id: "b2", type: .toolUse, name: "read_file"),
        ]
        #expect(ids(blocks) == ["b1", "b2"])
    }

    @Test func crlfInsideGroupTagStaysPlainText() {
        let text = "<group:Foo\r\nbar>"
        let result = MessageView.groupContentBlocks([textBlock("b1", text)])
        guard case .contentBlock(let block)? = result.first else {
            Issue.record("expected plain text content block"); return
        }
        #expect(result.count == 1)
        #expect(block.id == "b1")
        #expect(block.resolvedText == text)
    }

    @Test func streamingDeltaKeepsIdsOfAlreadyRenderedSegments() {
        let prefix = [textBlock("b1", "intro\n<group:Setup>\nreading")]
        let grown = [textBlock("b1", "intro\n<group:Setup>\nreading files\n</group>\nanswer")]
        let before = ids(prefix, isStreaming: true)
        let after = ids(grown, isStreaming: true)
        #expect(Array(after.prefix(before.count)) == before)
        #expect(after.count == before.count + 1)
    }

    @Test func groupIdStableAcrossOpenAndClose() {
        // The still-open group (streaming) and the later-closed group derive
        // the same id from the opening tag, so the group view isn't torn down
        // when the close tag arrives.
        let open = MessageView.groupContentBlocks(
            [textBlock("b1", "<group:Setup>\nworking")], isStreaming: true)
        let closed = MessageView.groupContentBlocks(
            [textBlock("b1", "<group:Setup>\nworking\n</group>")])
        guard case .group(let openGroup)? = open.last,
              case .group(let closedGroup)? = closed.last else {
            Issue.record("expected trailing groups")
            return
        }
        #expect(openGroup.id == closedGroup.id)
        #expect(openGroup.children.map(\.id) == closedGroup.children.map(\.id))
    }

    @Test func strippedIncompleteTagSegmentIdIsDeterministic() {
        let blocks = [textBlock("b1", "partial answer <gro")]
        let first = ids(blocks, isStreaming: true)
        let second = ids(blocks, isStreaming: true)
        #expect(first == second)
        // The first segment reuses the source block's id, so completing the
        // tag later doesn't re-identify the already-rendered leading run.
        #expect(first == ["b1"])
    }

    @Test func groupTagAppendedAfterPlainTextKeepsPrefixIdentity() {
        // A block with no group tags passes through under its raw id; when a
        // tag then streams into the same block, the leading text run must
        // keep that identity instead of flipping to a synthetic segment id.
        let before = ids([textBlock("b1", "intro text")], isStreaming: true)
        let after = ids([textBlock("b1", "intro text\n<group:Setup>\nworking")], isStreaming: true)
        #expect(before == ["b1"])
        #expect(Array(after.prefix(1)) == ["b1"])
        #expect(after.count == 2)
    }
}
