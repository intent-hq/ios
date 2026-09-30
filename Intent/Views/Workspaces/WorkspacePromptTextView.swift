import SwiftUI
import UIKit

/// Scoped to workspace creation: Return remains a newline on every device.
final class WorkspacePromptUITextView: UITextView {
    var onPasteImages: (() -> Void)?
    var allowsImagePaste = true

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            // hasImages is a metadata check; never read clipboard content on render/focus.
            return isEditable && allowsImagePaste && onPasteImages != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        // Both edit-menu Paste and Command-V use this responder action.
        guard UIPasteboard.general.hasImages else {
            super.paste(sender)
            return
        }
        guard allowsImagePaste, let onPasteImages else { return }
        onPasteImages()
    }
}

struct WorkspacePromptTextView: UIViewRepresentable {
    @Binding var text: String
    let minimumHeight: CGFloat
    let allowsImagePaste: Bool
    let onPasteImages: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WorkspacePromptUITextView {
        let view = WorkspacePromptUITextView()
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "creation.prompt"
        view.accessibilityLabel = String(localized: "What should we work on?")
        view.accessibilityHint = String(localized: "Optional. Add instructions for the first agent in this workspace.")
        view.registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self
        ]) { (view: WorkspacePromptUITextView, _: UITraitCollection) in
            view.font = Constants.Typography.bodyS.uiFont(compatibleWith: view.traitCollection)
        }
        return view
    }

    func updateUIView(_ view: WorkspacePromptUITextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteImages = onPasteImages
        view.allowsImagePaste = allowsImagePaste
        view.isEditable = isEnabled
        view.font = Constants.Typography.bodyS.uiFont(compatibleWith: view.traitCollection)
        view.textColor = UIColor(CreateWorkspaceFormStyle.foreground(for: colorScheme))
        if view.text != text, view.markedTextRange == nil { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WorkspacePromptUITextView, context _: Context) -> CGSize? {
        guard let width = proposal.width, let font = uiView.font else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lines = CreateWorkspaceView.initialMessageLineCountRange
        let contentHeight = min(max(fitting.height, font.lineHeight * CGFloat(lines.lowerBound)), font.lineHeight * CGFloat(lines.upperBound))
        // The native editor must fill the prompt's blank area so taps can focus it.
        // A minimum frame on its SwiftUI container only adds non-editable space.
        return CGSize(width: width, height: max(minimumHeight, contentHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WorkspacePromptTextView

        init(_ parent: WorkspacePromptTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
