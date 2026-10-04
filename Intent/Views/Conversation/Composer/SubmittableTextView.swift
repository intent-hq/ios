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
    var onPasteImages: (() -> Void)?
    var allowsImagePaste = true
    var imagePasteboard: ImagePasteboard = .general

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), imagePasteboard.hasImages() {
            // Metadata only: never read clipboard contents on focus or render.
            return isEditable && allowsImagePaste && onPasteImages != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        guard imagePasteboard.hasImages() else {
            pasteStandardContent(sender)
            return
        }
        // Edit-menu Paste and Command-V share this explicit user action.
        guard allowsImagePaste, let onPasteImages else { return }
        onPasteImages()
    }

    func pasteStandardContent(_ sender: Any?) {
        super.paste(sender)
    }

    /// Tracks whether Shift is currently held on a hardware keyboard.
    /// Used by the delegate to distinguish Shift+Return (newline) from
    /// software keyboard Return (submit).
    var isShiftHeld: Bool = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configureTypography()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTypography()
    }

    private func configureTypography() {
        // The token already applies UIFontMetrics. Resolve from current traits
        // rather than asking UITextView to scale the scaled font again.
        adjustsFontForContentSizeCategory = false
        updateTypography()
        registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self
        ]) { (textView: Self, _: UITraitCollection) in
            textView.updateTypography()
        }
    }

    func updateTypography() {
        let resolvedFont = Constants.Typography.bodyS.uiFont(compatibleWith: traitCollection)
        guard font != resolvedFont else { return }
        font = resolvedFont
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        centerShortContent()
        onLayoutChange?()
    }

    /// Content height measured with the base container inset, independent of
    /// any live vertical-centering inset, so the SwiftUI height clamp sees
    /// a stable value.
    var naturalHeight: CGFloat {
        let fitting = sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let base = Constants.Conversation.Composer.textContainerInset
        return fitting - textContainerInset.top - textContainerInset.bottom + base * 2
    }

    /// Centers short content within the minimum field height.
    private func centerShortContent() {
        let base = Constants.Conversation.Composer.textContainerInset
        let contentHeight = naturalHeight - base * 2
        let inset = contentHeight + base * 2 >= bounds.height
            ? base
            : (bounds.height - contentHeight) / 2
        guard abs(textContainerInset.top - inset) > 0.5 else { return }
        textContainerInset = UIEdgeInsets(top: inset, left: base, bottom: inset, right: base)
    }

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
            hasHardwareKeyboard: GCKeyboard.coalesced != nil
        )
    }

    // UIKit requires this override to remain optional; nil means no commands.
    // swiftlint:disable:next discouraged_optional_collection
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
    var onPasteImages: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    /// Reports the caret's UTF-16 offset (end of selection) on every
    /// selection change; used by visionOS dictation to insert at the caret.
    var onCaretChange: ((Int) -> Void)?
    /// Corner radius of the visionOS hover/highlight shape; defaults to the
    /// composer field's corners.
    var hoverCornerRadius: CGFloat = Constants.Conversation.Composer.fieldCornerRadius
    /// VoiceOver label for the text view (UITextView has no placeholder to
    /// announce, so a SwiftUI placeholder overlay does not label it).
    var accessibilityLabel: String?
    /// Opt-in foreground for a scoped composer design. Nil preserves UIKit's
    /// existing color without rewriting attributed text or changing editing policy.
    var textColor: UIColor?
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> KeyCommandTextView {
        let textView = KeyCommandTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.allowsImagePaste = isEnabled
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = "composer.textView"
        textView.backgroundColor = .clear
        #if os(visionOS)
        // Shape the system text-input hover/highlight effect to the composer
        // field's rounded corners; its default rect shape draws a rectangle
        // inside the rounded field (the outer RoundedRectangle clip in
        // MessageInputView does not affect it).
        textView.hoverStyle = UIHoverStyle(
            shape: .rect(cornerRadius: hoverCornerRadius)
        )
        #endif
        let inset = Constants.Conversation.Composer.textContainerInset
        textView.textContainerInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = text
        if let textColor { textView.textColor = textColor }

        // Report height whenever layout changes (e.g. initial layout, rotation)
        textView.onLayoutChange = { [weak textView] in
            guard let textView else { return }
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
        textView.onPasteImages = onPasteImages
        textView.allowsImagePaste = isEnabled
        textView.accessibilityLabel = accessibilityLabel
        textView.updateTypography()
        if let textColor, textView.textColor != textColor {
            textView.textColor = textColor
        }

        context.coordinator.synchronizeText(in: textView)

        // Sync focus
        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        } else if !isFocused, textView.isFirstResponder {
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

        func synchronizeText(in textView: KeyCommandTextView) {
            // A Binding read during updateUIView can be an older render snapshot.
            // Read it after that pass, through the current parent, so an edit
            // received meanwhile cannot be replaced by that snapshot (ios#575).
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let latestText = parent.text
                guard textView.text != latestText else { return }
                textView.text = latestText
                parent.onHeightChange?(textView.naturalHeight)
            }
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

        func textViewDidBeginEditing(_: UITextView) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_: UITextView) {
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
            shouldChangeTextIn _: NSRange,
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
