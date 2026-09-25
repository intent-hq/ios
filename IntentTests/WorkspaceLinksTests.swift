@testable import Intent
import Testing

struct WorkspaceLinksTests {
    @Test(arguments: ["@", "@@", "@@@", "@@@work", "@@@workspace", "@@@workspace\nalpha\n"])
    func hidesStreamingWorkspaceMarkers(_ fragment: String) {
        #expect(WorkspaceLinks.parse("Before\n" + fragment, isStreaming: true) == [.markdown("Before\n")])
        #expect(WorkspaceLinks.parse(fragment, isStreaming: false) == [.markdown(fragment)])
    }

    @Test func completedStreamingBlockBecomesCards() {
        #expect(WorkspaceLinks.parse("@@@workspace\nalpha\n@@@", isStreaming: true) == [.workspaces(["alpha"])])
        let code = "```text\n@@@workspace\nalpha"
        #expect(WorkspaceLinks.parse(code, isStreaming: true) == [.markdown(code)])
    }

    @Test func parsesWorkspaceListsAndPreservesProse() {
        let text = "Before\n\n@@@workspace\n- `alpha`\n* beta\nintent://local/workspace/gamma\nalpha\n@@@\n\nAfter"
        #expect(WorkspaceLinks.parse(text) == [
            .markdown("Before\n\n"), .workspaces(["alpha", "beta", "gamma"]), .markdown("\nAfter")
        ])
    }

    @Test func supportsLegacyWorkspaceFence() {
        #expect(WorkspaceLinks.parse("```workspace\nalpha\n```") == [.workspaces(["alpha"])])
    }

    @Test(arguments: [
        "@@@workspace\nalpha", "@@@workspace\n\n@@@", "@@@workspace\nnot a workspace ID\n@@@",
        "```text\n@@@workspace\nalpha\n@@@\n```", "~~~workspace\nalpha\n~~~",
        "````text\n```\n@@@workspace\nalpha\n@@@\n````",
        "    @@@workspace\n    alpha\n    @@@", "`@@@workspace alpha @@@`", "alpha\nbeta"
    ])
    func preservesIncompleteInvalidAndLiteralBlocks(_ text: String) {
        #expect(WorkspaceLinks.parse(text) == [.markdown(text)])
    }

    @Test func parsesMultipleBlocksWithWindowsNewlines() {
        #expect(WorkspaceLinks.parse("@@@workspace\r\nalpha\r\n@@@\r\n@@@workspace\r\nbeta\r\n@@@") == [
            .workspaces(["alpha"]), .workspaces(["beta"])
        ])
    }

    @Test func coalescesSplitTextWithoutCrossingTools() {
        let blocks = [
            ContentBlock(id: "first", type: .text, text: "@@@work"),
            ContentBlock(id: "second", type: .text, text: "space\nalpha\n@@@"),
            ContentBlock(id: "tool", type: .toolUse),
            ContentBlock(id: "after", type: .text, text: "After")
        ]
        let combined = WorkspaceLinks.coalescingTextBlocks(blocks)
        #expect(combined.map(\.id) == ["first", "tool", "after"])
        #expect(WorkspaceLinks.parse(combined[0].resolvedText ?? "") == [.workspaces(["alpha"])])
        #expect(combined[1] == blocks[2])
        #expect(combined[2] == blocks.last)
    }

    @Test func doesNotMergeAcrossToolOrChangeOrdinaryText() {
        let blocks = [
            ContentBlock(id: "first", type: .text, text: "@@@workspace\nalpha"),
            ContentBlock(id: "tool", type: .toolUse),
            ContentBlock(id: "second", type: .text, text: "\n@@@"),
            ContentBlock(id: "third", type: .text, text: "After")
        ]
        #expect(WorkspaceLinks.coalescingTextBlocks(blocks) == blocks)
    }
}
