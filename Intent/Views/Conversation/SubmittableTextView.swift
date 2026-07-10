import SwiftUI
import UIKit

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
        onLayoutChange?()
    }

    override var keyCommands: [UIKeyCommand]? {
        // On iPhone, don't intercept Return — it should always insert a newline
        guard UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        // Intercept bare Return (no modifiers) on iPad — calls handleReturn
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

    func makeUIView(context: Context) -> KeyCommandTextView {
        let textView = KeyCommandTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = text

        // Report height whenever layout changes (e.g. initial layout, rotation)
        textView.onLayoutChange = { [weak textView] in
            guard let textView = textView else { return }
            let h = textView.sizeThatFits(
                CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            ).height
            onHeightChange?(h)
        }

        return textView
    }

    func updateUIView(_ textView: KeyCommandTextView, context: Context) {
        // Update onSubmit closure so it always captures current state
        textView.onSubmit = onSubmit

        // Sync text from SwiftUI → UIKit (avoid cursor jump during editing)
        if textView.text != text {
            textView.text = text

            let idealHeight = textView.sizeThatFits(
                CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            ).height
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
            let idealHeight = textView.sizeThatFits(
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
                // On iPhone, Enter always inserts a newline (send via button only)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    return true
                }
                // iPad software keyboard Return (or bare Return fallback) → submit
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

