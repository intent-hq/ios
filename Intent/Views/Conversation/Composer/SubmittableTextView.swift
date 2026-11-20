import GameController
import SwiftUI
import UIKit

enum ComposerSubmitPolicy {
    static func returnSubmits(
        isVisionOS: Bool,
        idiom: UIUserInterfaceIdiom,
        hasHardwareKeyboard: Bool
    ) -> Bool {
        isVisionOS ? hasHardwareKeyboard : idiom == .pad
    }
}

class KeyCommandTextView: UITextView {
    var onSubmit: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onPasteImages: (() -> Void)?
    weak var skillCompletion: ComposerSkillCompletion?
    var allowsImagePaste = true
    var imagePasteboard: ImagePasteboard = .general

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), imagePasteboard.hasImages() {
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
        guard allowsImagePaste, let onPasteImages else { return }
        onPasteImages()
    }

    func pasteStandardContent(_ sender: Any?) {
        super.paste(sender)
    }

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

    var naturalHeight: CGFloat {
        let fitting = sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let base = Constants.Conversation.Composer.textContainerInset
        return fitting - textContainerInset.top - textContainerInset.bottom + base * 2
    }

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

    static var returnSubmitsNow: Bool {
        ComposerSubmitPolicy.returnSubmits(
            isVisionOS: isVisionOS,
            idiom: UIDevice.current.userInterfaceIdiom,
            hasHardwareKeyboard: GCKeyboard.coalesced != nil
        )
    }

    // swiftlint:disable:next discouraged_optional_collection
    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        if skillCompletion?.context != nil {
            commands = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\t", UIKeyCommand.inputEscape].map { input in
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleSkillCommand(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        guard Self.returnSubmitsNow else { return commands }
        let returnCommand = UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(handleReturn)
        )
        return commands + [returnCommand]
    }

    @objc private func handleReturn() {
        if skillCompletion?.acceptSelection() == true { return }
        onSubmit?()
    }

    @objc private func handleSkillCommand(_ command: UIKeyCommand) {
        switch command.input {
        case UIKeyCommand.inputUpArrow: skillCompletion?.moveSelection(by: -1)
        case UIKeyCommand.inputDownArrow: skillCompletion?.moveSelection(by: 1)
        case UIKeyCommand.inputEscape: skillCompletion?.dismiss()
        case "\t": skillCompletion?.acceptSelection()
        default: break
        }
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

struct SubmittableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onPasteImages: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onCaretChange: ((Int) -> Void)?
    var hoverCornerRadius: CGFloat = Constants.Conversation.Composer.fieldCornerRadius
    var accessibilityLabel: String?
    var textColor: UIColor?
    var skillCompletion: ComposerSkillCompletion?
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> KeyCommandTextView {
        let textView = KeyCommandTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.skillCompletion = skillCompletion
        textView.allowsImagePaste = isEnabled
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = "composer.textView"
        textView.backgroundColor = .clear
        #if os(visionOS)
        textView.hoverStyle = UIHoverStyle(
            shape: .rect(cornerRadius: hoverCornerRadius)
        )
        #endif
        let inset = Constants.Conversation.Composer.textContainerInset
        textView.textContainerInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        textView.isScrollEnabled = true
        textView.clipsToBounds = true
        textView.alwaysBounceVertical = false
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = text
        if let textColor { textView.textColor = textColor }

        textView.onLayoutChange = { [weak textView] in
            guard let textView else { return }
            onHeightChange?(textView.naturalHeight)
        }

        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView _: KeyCommandTextView, context _: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ textView: KeyCommandTextView, context: Context) {
        context.coordinator.parent = self

        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.skillCompletion = skillCompletion
        textView.allowsImagePaste = isEnabled
        textView.accessibilityLabel = accessibilityLabel
        textView.updateTypography()
        if let textColor, textView.textColor != textColor {
            textView.textColor = textColor
        }

        context.coordinator.synchronizeText(in: textView)
        context.coordinator.synchronizeFocus(in: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: SubmittableTextView
        private var nativeFocusRevision = 0

        init(_ parent: SubmittableTextView) {
            self.parent = parent
        }

        func synchronizeFocus(in textView: KeyCommandTextView) {
            let revision = nativeFocusRevision
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, nativeFocusRevision == revision else { return }
                if parent.isFocused, !textView.isFirstResponder {
                    textView.becomeFirstResponder()
                } else if !parent.isFocused, textView.isFirstResponder {
                    textView.resignFirstResponder()
                }
            }
        }

        func synchronizeText(in textView: KeyCommandTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let latestText = parent.text
                guard textView.text != latestText else { return }
                textView.text = latestText
                parent.onHeightChange?(textView.naturalHeight)
                parent.skillCompletion?.update(from: textView)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.skillCompletion?.update(from: textView)

            let idealHeight = (textView as? KeyCommandTextView)?.naturalHeight
                ?? textView.sizeThatFits(
                    CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
                ).height
            parent.onHeightChange?(idealHeight)

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
            parent.skillCompletion?.update(from: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            nativeFocusRevision &+= 1
            parent.skillCompletion?.update(from: textView)
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            nativeFocusRevision &+= 1
            parent.skillCompletion?.update(from: textView)
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn _: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n" {
                if let kbTextView = textView as? KeyCommandTextView, kbTextView.isShiftHeld {
                    return true
                }
                guard KeyCommandTextView.returnSubmitsNow else { return true }
                if parent.skillCompletion?.acceptSelection() == true { return false }
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}
