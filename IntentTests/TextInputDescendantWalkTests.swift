@testable import Intent
import Testing
import UIKit

@MainActor
struct TextInputDescendantWalkTests {
    private func makeTextInputView(frame: CGRect) -> UIView {
        let view = UITextView(frame: frame)
        view.isEditable = false
        return view
    }

    @Test func findsTextInputThroughZeroFramedWrapper() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
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
