import SwiftUI
import Testing
import UIKit
@testable import Intent

/// Availability gate for the copy-context-menu interaction
/// (MessageCopyContextMenu): the overlay is applied unconditionally so the
/// row subtree never changes structural identity, and this predicate only
/// decides whether the overlay carries a live `UIContextMenuInteraction`.
/// The interaction attaches once the message has settled and there is text
/// to copy — image-only rows and live streaming rows stay inert.
struct MessageCopyContextMenuGatingTests {
    @Test func emptyTextNeverEnables() {
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "", isStreaming: false))
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "", isStreaming: true))
    }

    /// The first text delta makes the copy text non-empty while the turn is
    /// still streaming — the interaction must NOT attach mid-stream.
    @Test func streamingRowWithTextDoesNotEnable() {
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: "partial delta", isStreaming: true))
    }

    /// Settled rows with copyable text keep the upright-lift-preview
    /// interaction from #140.
    @Test func settledRowWithTextEnables() {
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: "final answer", isStreaming: false))
    }

    /// User rows never stream and pass isStreaming: false — a non-empty
    /// user bubble gets the interaction exactly as before the gate.
    @Test func userRowBehaviorUnchanged() {
        let copyText = MessageView.userCopyText(from: [
            ContentBlock(id: "u1", type: .text, text: "hello there")
        ])
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: copyText, isStreaming: false))
    }

    /// End-to-end shape of the assistant flow: during the thinking phase
    /// assistantCopyText is empty (no interaction); after the first text
    /// delta it is non-empty, and only the streaming flag keeps the row
    /// inert until the turn settles.
    @Test func assistantCopyTextDrivesTheGateAcrossPhases() {
        let thinkingOnly: [ContentBlock] = [
            ContentBlock(id: "t1", type: .thinking, text: "reasoning...")
        ]
        let thinkingText = MessageView.assistantCopyText(from: thinkingOnly)
        #expect(thinkingText.isEmpty)
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: thinkingText, isStreaming: true))

        let withDelta = thinkingOnly + [
            ContentBlock(id: "t2", type: .text, text: "first streamed words")
        ]
        let deltaText = MessageView.assistantCopyText(from: withDelta)
        #expect(!deltaText.isEmpty)
        #expect(!MessageCopyContextMenu.shouldEnableCopyInteraction(text: deltaText, isStreaming: true))
        #expect(MessageCopyContextMenu.shouldEnableCopyInteraction(text: deltaText, isStreaming: false))
    }
}

/// Selective hit-testing of the transparent overlay
/// (CopyContextMenuOverlay.OverlayView): as a sibling above the row content
/// it must claim touches over plain SwiftUI regions (the underlying hit view
/// is its ancestor — the hosting view — whose gesture recognizers still see
/// the touch), pass touches through to UIKit-backed sibling subtrees
/// (in-row scroll views), and be completely inert while the interaction is
/// disabled.
@MainActor
struct CopyContextMenuOverlayHitTestTests {
    private func makeOverlay(enabled: Bool) -> CopyContextMenuOverlay.OverlayView {
        let overlay = CopyContextMenuOverlay.OverlayView()
        let coordinator = CopyContextMenuOverlay.Coordinator(
            text: "copy me", preview: AnyView(EmptyView())
        )
        overlay.setInteractionEnabled(enabled, delegate: coordinator)
        return overlay
    }

    @Test func disabledOverlayIsInvisibleToHitTesting() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let overlay = makeOverlay(enabled: false)
        overlay.frame = host.bounds
        host.addSubview(overlay)
        let hit = host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(hit === host)
    }

    @Test func overlayClaimsTouchesOverPlainContent() {
        // No UIKit-backed sibling below: the probe finds the host (an
        // ancestor), so the overlay claims the touch for its interaction.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let overlay = makeOverlay(enabled: true)
        overlay.frame = host.bounds
        host.addSubview(overlay)
        let hit = host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(hit === overlay)
    }

    @Test func overlayPassesThroughToUIKitBackedSiblings() {
        // A scroll view beneath the overlay (e.g. a code block) must keep
        // receiving its touches; the overlay yields over that sub-region
        // and still claims the rest of the row.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 50, height: 100))
        host.addSubview(scrollView)
        let overlay = makeOverlay(enabled: true)
        overlay.frame = host.bounds
        host.addSubview(overlay)
        #expect(host.hitTest(CGPoint(x: 25, y: 50), with: nil) === scrollView)
        #expect(host.hitTest(CGPoint(x: 75, y: 50), with: nil) === overlay)
    }

    @Test func hitTestProbeRestoresUserInteraction() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let overlay = makeOverlay(enabled: true)
        overlay.frame = host.bounds
        host.addSubview(overlay)
        _ = host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(overlay.isUserInteractionEnabled)
    }
}
