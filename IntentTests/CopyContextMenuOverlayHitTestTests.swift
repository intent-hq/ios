import Testing
import UIKit
@testable import Intent

/// The overlay's hit-test pass-through defers to a `UITextInput`-conforming
/// descendant (Textual's text-interaction view) that claims the point, even
/// when an intermediate SwiftUI wrapper is zero-framed and would make the
/// regular recursive hit-test skip the subtree. These tests exercise the
/// `textInputDescendant(containing:with:excluding:)` walk directly.
@MainActor
struct CopyContextMenuOverlayHitTestTests {
    /// Minimal `UITextInput` conformance is impractical to stub; the walk
    /// only checks protocol conformance, so a UITextView (which conforms)
    /// stands in for Textual's interaction view.
    private func makeTextInputView(frame: CGRect) -> UIView {
        let view = UITextView(frame: frame)
        view.isEditable = false
        return view
    }

    @Test func findsTextInputThroughZeroFramedWrapper() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        // Zero-framed intermediate wrapper: regular hit-testing would fail
        // its containment check and never descend into it.
        let wrapper = UIView(frame: .zero)
        let textInput = makeTextInputView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        container.addSubview(wrapper)
        wrapper.addSubview(textInput)
        let overlay = UIView(frame: container.bounds)
        container.addSubview(overlay)

        let match = container.textInputDescendant(
            containing: CGPoint(x: 150, y: 50), with: nil, excluding: overlay
        )

        #expect(match === textInput)
    }

    /// Coordinate conversion accumulates wrapper frames hop by hop, so a
    /// non-zero-origin wrapper offsets the point on the way down — a text
    /// input that compensates (correct absolute position) is still found.
    @Test func findsTextInputUnderOffsetWrapper() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let wrapper = UIView(frame: CGRect(x: 50, y: 25, width: 0, height: 0))
        let textInput = makeTextInputView(frame: CGRect(x: -50, y: -25, width: 300, height: 100))
        container.addSubview(wrapper)
        wrapper.addSubview(textInput)
        let overlay = UIView(frame: container.bounds)
        container.addSubview(overlay)

        let match = container.textInputDescendant(
            containing: CGPoint(x: 150, y: 50), with: nil, excluding: overlay
        )

        #expect(match === textInput)
    }

    /// The walk ignores wrapper *bounds* but not wrapper state: a hidden or
    /// disabled intermediate wrapper prunes its whole subtree.
    @Test func skipsTextInputUnderHiddenOrDisabledWrapper() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let frame = CGRect(x: 0, y: 0, width: 300, height: 100)

        let hiddenWrapper = UIView(frame: frame)
        hiddenWrapper.isHidden = true
        hiddenWrapper.addSubview(makeTextInputView(frame: frame))
        let disabledWrapper = UIView(frame: frame)
        disabledWrapper.isUserInteractionEnabled = false
        disabledWrapper.addSubview(makeTextInputView(frame: frame))
        container.addSubview(hiddenWrapper)
        container.addSubview(disabledWrapper)
        let overlay = UIView(frame: container.bounds)
        container.addSubview(overlay)

        let match = container.textInputDescendant(
            containing: CGPoint(x: 150, y: 50), with: nil, excluding: overlay
        )

        #expect(match == nil)
    }

    @Test func returnsNilWhenPointOutsideTextInput() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let textInput = makeTextInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        container.addSubview(textInput)
        let overlay = UIView(frame: container.bounds)
        container.addSubview(overlay)

        let match = container.textInputDescendant(
            containing: CGPoint(x: 250, y: 50), with: nil, excluding: overlay
        )

        #expect(match == nil)
    }

    @Test func skipsHiddenAndDisabledCandidates() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let frame = CGRect(x: 0, y: 0, width: 300, height: 100)

        let hidden = makeTextInputView(frame: frame)
        hidden.isHidden = true
        let disabled = makeTextInputView(frame: frame)
        disabled.isUserInteractionEnabled = false
        let transparent = makeTextInputView(frame: frame)
        transparent.alpha = 0
        container.addSubview(hidden)
        container.addSubview(disabled)
        container.addSubview(transparent)
        let overlay = UIView(frame: container.bounds)
        container.addSubview(overlay)

        let match = container.textInputDescendant(
            containing: CGPoint(x: 150, y: 50), with: nil, excluding: overlay
        )

        #expect(match == nil)
    }

    @Test func excludedSubtreeIsPruned() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let overlay = UIView(frame: container.bounds)
        let nestedInOverlay = makeTextInputView(frame: container.bounds)
        overlay.addSubview(nestedInOverlay)
        container.addSubview(overlay)

        let match = container.textInputDescendant(
            containing: CGPoint(x: 150, y: 50), with: nil, excluding: overlay
        )

        #expect(match == nil)
    }

    @Test func plainViewsDoNotMatch() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let plain = UIView(frame: container.bounds)
        container.addSubview(plain)
        let overlay = UIView(frame: container.bounds)
        container.addSubview(overlay)

        let match = container.textInputDescendant(
            containing: CGPoint(x: 150, y: 50), with: nil, excluding: overlay
        )

        #expect(match == nil)
    }
}
