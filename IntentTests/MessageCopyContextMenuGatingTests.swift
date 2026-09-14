@testable import Intent
import SwiftUI
import Testing
import UIKit

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
/// disabled. The probe runs from the window, so every fixture is rooted in
/// a real `UIWindow`.
@MainActor
struct CopyContextMenuOverlayHitTestTests {
    /// Holds the fixture's strong references: `UIContextMenuInteraction`
    /// keeps its delegate weakly, so the coordinator must outlive the
    /// assertions for the fixture to stay realistic.
    private struct Fixture {
        let window: UIWindow
        let host: UIView
        let overlay: CopyContextMenuOverlay.OverlayView
        let coordinator: CopyContextMenuOverlay.Coordinator
    }

    /// Builds `window > host > [siblings..., overlay]`. With `wrapped: true`
    /// the overlay sits inside an intermediate wrapper sized exactly to it,
    /// mimicking SwiftUI's per-representable wrapper in production.
    private func makeFixture(enabled: Bool, wrapped: Bool = false) -> Fixture {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let window = UIWindow(frame: frame)
        window.isHidden = false
        let host = UIView(frame: frame)
        window.addSubview(host)
        let overlay = CopyContextMenuOverlay.OverlayView()
        let coordinator = CopyContextMenuOverlay.Coordinator(
            text: "copy me",
            preview: AnyView(EmptyView())
        )
        overlay.setInteractionEnabled(enabled, delegate: coordinator)
        if wrapped {
            let wrapper = UIView(frame: host.bounds)
            overlay.frame = wrapper.bounds
            wrapper.addSubview(overlay)
            host.addSubview(wrapper)
        } else {
            overlay.frame = host.bounds
            host.addSubview(overlay)
        }
        return Fixture(window: window, host: host, overlay: overlay, coordinator: coordinator)
    }

    @Test func disabledOverlayIsInvisibleToHitTesting() {
        let fixture = makeFixture(enabled: false)
        let hit = fixture.host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(hit === fixture.host)
    }

    @Test func overlayClaimsTouchesOverPlainContent() {
        // No UIKit-backed sibling below: the probe finds the host (an
        // ancestor), so the overlay claims the touch for its interaction.
        let fixture = makeFixture(enabled: true)
        let hit = fixture.host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(hit === fixture.overlay)
    }

    @Test func overlayPassesThroughToUIKitBackedSiblings() {
        // A scroll view beneath the overlay (e.g. a code block) must keep
        // receiving its touches; the overlay yields over that sub-region
        // and still claims the rest of the row.
        let fixture = makeFixture(enabled: true)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 50, height: 100))
        fixture.host.insertSubview(scrollView, belowSubview: fixture.overlay)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === scrollView)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func probeSeesSiblingsThroughSizedWrapper() throws {
        // Production shape: the overlay's immediate superview is SwiftUI's
        // per-representable wrapper, sized exactly to the overlay with the
        // overlay as its only subview. A probe from that superview could
        // only ever find the wrapper; the window-rooted probe must disable
        // the wrapper chain and still find the scroll view beneath.
        let fixture = makeFixture(enabled: true, wrapped: true)
        let wrapper = try #require(fixture.overlay.superview)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 50, height: 100))
        fixture.host.insertSubview(scrollView, belowSubview: wrapper)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === scrollView)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func hitTestProbeRestoresUserInteraction() throws {
        let fixture = makeFixture(enabled: true, wrapped: true)
        let wrapper = try #require(fixture.overlay.superview)
        _ = fixture.host.hitTest(CGPoint(x: 50, y: 50), with: nil)
        #expect(fixture.overlay.isUserInteractionEnabled)
        #expect(wrapper.isUserInteractionEnabled)
    }

    @Test func overlayPassesThroughToImagePassthroughMarker() {
        // A pass-through marker (the background of a tappable image
        // thumbnail) beneath the overlay: the probe resolves to the marker,
        // so the touch reaches the SwiftUI Button above it instead of
        // being claimed for the copy interaction. The rest of the row is
        // still claimed.
        let fixture = makeFixture(enabled: true)
        let marker = CopyContextMenuPassthroughMarker.MarkerView(
            frame: CGRect(x: 0, y: 0, width: 50, height: 100)
        )
        fixture.host.insertSubview(marker, belowSubview: fixture.overlay)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === marker)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }

    @Test func overlayFindsPassthroughMarkerUnderZeroFramedWrapper() {
        // Regular hit-testing never descends into a zero-framed wrapper, so
        // the probe resolves to the host (an ancestor); the overlay must
        // still find the correctly-framed marker beneath it.
        let fixture = makeFixture(enabled: true)
        let wrapper = UIView(frame: .zero)
        let marker = CopyContextMenuPassthroughMarker.MarkerView(
            frame: CGRect(x: 0, y: 0, width: 50, height: 100)
        )
        wrapper.addSubview(marker)
        fixture.host.insertSubview(wrapper, belowSubview: fixture.overlay)
        #expect(fixture.host.hitTest(CGPoint(x: 25, y: 50), with: nil) === marker)
        #expect(fixture.host.hitTest(CGPoint(x: 75, y: 50), with: nil) === fixture.overlay)
    }
}
