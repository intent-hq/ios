import GameController
import SwiftUI
import UIKit

/// Decides whether bare Return submits the composer message (Shift+Return
/// always inserts a newline).
///
/// - visionOS: dictation-first — Return submits only while a hardware
///   keyboard is connected (`GCKeyboard.coalesced`); the virtual keyboard's
///   Return inserts a newline so the composer sends via the button.
/// - iPad: Return always submits.
/// - iPhone: Return always inserts a newline (send via button only).
enum ComposerSubmitPolicy {
    static func returnSubmits(
        isVisionOS: Bool,
        idiom: UIUserInterfaceIdiom,
        hasHardwareKeyboard: Bool
    ) -> Bool {
        isVisionOS ? hasHardwareKeyboard : idiom == .pad
    }
}

/// A UITextView subclass that intercepts hardware keyboard Return to submit,
/// while letting Shift+Return insert a newline.
class KeyCommandTextView: UITextView {
    var onSubmit: (() -> Void)?
    var onLayoutChange: (() -> Void)?

    /// Tracks whether Shift is currently held on a hardware keyboard.
    /// Used by the delegate to distinguish Shift+Return (newline) from
    /// software keyboard Return (submit).
    var isShiftHeld: Bool = false

    override func layoutSubviews() {
        super.layoutSubviews()
        #if os(visionOS)
        centerShortContent()
        #endif
        onLayoutChange?()
    }

    /// Content height measured with the base container inset, independent of
    /// any live vertical-centering inset (visionOS), so the SwiftUI height
    /// clamp sees a stable value. On iOS the insets always equal the base,
    /// so this matches `sizeThatFits` exactly.
    var naturalHeight: CGFloat {
        let fitting = sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let base = Constants.Conversation.Composer.textContainerInset
        return fitting - textContainerInset.top - textContainerInset.bottom + base * 2
    }

    #if os(visionOS)
    /// Vertically centers short content inside the fixed 60 pt minimum field
    /// height by widening the vertical container insets symmetrically.
    private func centerShortContent() {
        let base = Constants.Conversation.Composer.textContainerInset
        let contentHeight = naturalHeight - base * 2
        let inset = contentHeight + base * 2 >= bounds.height
            ? base
            : (bounds.height - contentHeight) / 2
        guard abs(textContainerInset.top - inset) > 0.5 else { return }
        textContainerInset = UIEdgeInsets(top: inset, left: base, bottom: inset, right: base)
    }
    #endif

    #if os(visionOS)
    private static let isVisionOS = true
    #else
    private static let isVisionOS = false
    #endif

    /// Live submit rule for the current platform, idiom, and hardware
    /// keyboard state.
    static var returnSubmitsNow: Bool {
        ComposerSubmitPolicy.returnSubmits(
            isVisionOS: isVisionOS,
            idiom: UIDevice.current.userInterfaceIdiom,
            hasHardwareKeyboard: GCKeyboard.coalesced != nil)
    }

    override var keyCommands: [UIKeyCommand]? {
        // Don't intercept Return where it should insert a newline (iPhone
        // always; visionOS without a hardware keyboard)
        guard Self.returnSubmitsNow else { return nil }
        // Intercept bare Return (no modifiers) — calls handleReturn
        let returnCommand = UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(handleReturn)
        )
        return [returnCommand]
    }

    @objc private func handleReturn() {
        onSubmit?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = true
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = false
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = false
            }
        }
        super.pressesCancelled(presses, with: event)
    }
}

/// A SwiftUI wrapper around UITextView that supports:
/// - Two-way text binding
/// - Hardware keyboard Enter → onSubmit, Shift+Enter → newline
/// - Software keyboard Return → onSubmit (matches iMessage behavior)
/// - Focus state via isFocused binding
struct SubmittableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onHeightChange: ((CGFloat) -> Void)?
    /// Reports the caret's UTF-16 offset (end of selection) on every
    /// selection change; used by visionOS dictation to insert at the caret.
    var onCaretChange: ((Int) -> Void)?

    func makeUIView(context: Context) -> KeyCommandTextView {
        let textView = KeyCommandTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        #if os(visionOS)
        // Shape the system text-input hover/highlight effect to the composer
        // field's rounded corners; its default rect shape draws a rectangle
        // inside the rounded field (the outer RoundedRectangle clip in
        // MessageInputView does not affect it).
        textView.hoverStyle = UIHoverStyle(
            shape: .rect(cornerRadius: Constants.Conversation.Composer.fieldCornerRadius))
        #endif
        let inset = Constants.Conversation.Composer.textContainerInset
        textView.textContainerInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = text

        // Report height whenever layout changes (e.g. initial layout, rotation)
        textView.onLayoutChange = { [weak textView] in
            guard let textView = textView else { return }
            onHeightChange?(textView.naturalHeight)
        }

        return textView
    }

    func updateUIView(_ textView: KeyCommandTextView, context: Context) {
        // Keep the coordinator's parent current so its closures (e.g.
        // onCaretChange) capture the latest state
        context.coordinator.parent = self

        // Update onSubmit closure so it always captures current state
        textView.onSubmit = onSubmit

        // Sync text from SwiftUI → UIKit (avoid cursor jump during editing)
        if textView.text != text {
            textView.text = text

            let idealHeight = textView.naturalHeight
            DispatchQueue.main.async {
                self.onHeightChange?(idealHeight)
            }
        }

        // Sync focus
        if isFocused && !textView.isFirstResponder {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        } else if !isFocused && textView.isFirstResponder {
            DispatchQueue.main.async { textView.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: SubmittableTextView

        init(_ parent: SubmittableTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text

            // Report ideal content height to SwiftUI
            let idealHeight = (textView as? KeyCommandTextView)?.naturalHeight
                ?? textView.sizeThatFits(
                    CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
                ).height
            parent.onHeightChange?(idealHeight)

            // Scroll to keep cursor visible
            if let selectedRange = textView.selectedTextRange {
                DispatchQueue.main.async {
                    let caretRect = textView.caretRect(for: selectedRange.end)
                    textView.scrollRectToVisible(caretRect, animated: false)
                }
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            parent.onCaretChange?(range.location + range.length)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        /// Intercepts Return from the software keyboard to submit.
        /// Hardware bare-Return is handled by UIKeyCommand (never reaches here).
        /// Hardware Shift+Return bypasses UIKeyCommand and arrives here — we
        /// detect the held Shift key and allow the newline insertion.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n" {
                // Shift+Return on hardware keyboard → insert newline
                if let kbTextView = textView as? KeyCommandTextView, kbTextView.isShiftHeld {
                    return true
                }
                // Return inserts a newline where the submit rule is off
                // (iPhone always; visionOS without a hardware keyboard)
                guard KeyCommandTextView.returnSubmitsNow else { return true }
                // Software keyboard Return (or bare Return fallback) → submit
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

