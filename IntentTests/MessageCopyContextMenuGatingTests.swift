import Testing
@testable import Intent

/// Streaming gate for the copy-context-menu host (MessageCopyContextMenu):
/// a live streaming assistant row must stay on the plain SwiftUI branch —
/// routing it through CopyContextMenuHost's nested hosting controller froze
/// the row at its thinking-phase height (the host's sizeRevision
/// invalidation fires during the layout pass and is dropped), so streamed
/// content rendered invisibly. The host may only attach once the message
/// has settled and there is text to copy.
struct MessageCopyContextMenuGatingTests {
    @Test func emptyTextNeverHosts() {
        #expect(!MessageCopyContextMenu.shouldHostCopyMenu(text: "", isStreaming: false))
        #expect(!MessageCopyContextMenu.shouldHostCopyMenu(text: "", isStreaming: true))
    }

    /// The regression: the first text delta makes the copy text non-empty
    /// while the turn is still streaming — the row must NOT flip into the
    /// hosting controller mid-stream.
    @Test func streamingRowWithTextDoesNotHost() {
        #expect(!MessageCopyContextMenu.shouldHostCopyMenu(text: "partial delta", isStreaming: true))
    }

    /// Settled rows with copyable text keep the upright-lift-preview host
    /// from #140.
    @Test func settledRowWithTextHosts() {
        #expect(MessageCopyContextMenu.shouldHostCopyMenu(text: "final answer", isStreaming: false))
    }

    /// User rows never stream and pass isStreaming: false — a non-empty
    /// user bubble hosts exactly as before the gate.
    @Test func userRowBehaviorUnchanged() {
        let copyText = MessageView.userCopyText(from: [
            ContentBlock(id: "u1", type: .text, text: "hello there")
        ])
        #expect(MessageCopyContextMenu.shouldHostCopyMenu(text: copyText, isStreaming: false))
    }

    /// End-to-end shape of the assistant flow: during the thinking phase
    /// assistantCopyText is empty (no host); after the first text delta it
    /// is non-empty, and only the streaming flag keeps the row plain until
    /// the turn settles.
    @Test func assistantCopyTextDrivesTheGateAcrossPhases() {
        let thinkingOnly: [ContentBlock] = [
            ContentBlock(id: "t1", type: .thinking, text: "reasoning...")
        ]
        let thinkingText = MessageView.assistantCopyText(from: thinkingOnly)
        #expect(thinkingText.isEmpty)
        #expect(!MessageCopyContextMenu.shouldHostCopyMenu(text: thinkingText, isStreaming: true))

        let withDelta = thinkingOnly + [
            ContentBlock(id: "t2", type: .text, text: "first streamed words")
        ]
        let deltaText = MessageView.assistantCopyText(from: withDelta)
        #expect(!deltaText.isEmpty)
        #expect(!MessageCopyContextMenu.shouldHostCopyMenu(text: deltaText, isStreaming: true))
        #expect(MessageCopyContextMenu.shouldHostCopyMenu(text: deltaText, isStreaming: false))
    }
}
