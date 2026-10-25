import SwiftUI
import UIKit

/// Keep the same editor and first responder when showing or hiding the token.
struct ManualTokenTextField: UIViewRepresentable {
    @Binding var text: String
    let isSecure: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.borderStyle = .none
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.keyboardType = .asciiCapable
        field.returnKeyType = .done
        field.clearsOnBeginEditing = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityLabel = String(localized: "API Token")
        field.accessibilityIdentifier = "manual.token"
        field.registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self
        ]) { (field: UITextField, _: UITraitCollection) in
            Self.updateTypography(field)
        }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        Self.updateTypography(field)
        let foreground = UIColor(Constants.Pairing.foreground(for: colorScheme))
        field.textColor = foreground
        field.attributedPlaceholder = NSAttributedString(
            string: String(localized: "Paste token"),
            attributes: [.foregroundColor: foreground.withAlphaComponent(Constants.ConnectionSheet.placeholderOpacity)]
        )
        field.isEnabled = isEnabled
        if field.isSecureTextEntry != isSecure { updateSecureEntry(field) }
        if field.text != text { field.text = text }
        // UIKit owns tap focus. A SwiftUI FocusState with no registered token
        // target can reset to nil and immediately undo becomeFirstResponder.
        if !isEnabled, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    private static func updateTypography(_ field: UITextField) {
        let style = Constants.Typography.bodySEmphasized
        let font = style.uiFont(compatibleWith: field.traitCollection)
        guard field.font != font else { return }
        field.font = font
        field.defaultTextAttributes[.kern] = Constants.Pairing.optionTitleTracking * font.pointSize / style.size
        field.invalidateIntrinsicContentSize()
    }

    private func updateSecureEntry(_ field: UITextField) {
        let selection = field.selectedTextRange
        let draft = field.text ?? ""
        field.isSecureTextEntry = isSecure
        if field.isFirstResponder {
            // Refresh secure-entry storage so the next keystroke appends instead
            // of replacing the existing draft. Keep the keyboard and selection.
            field.text = ""
            field.insertText(draft)
        } else {
            field.text = draft
        }
        field.selectedTextRange = selection
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context _: Context) -> CGSize? {
        guard let width = proposal.width, let font = uiView.font else { return nil }
        return CGSize(width: width, height: ceil(font.lineHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ field: UITextField, coordinator _: Coordinator) {
        field.delegate = nil
        field.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ManualTokenTextField
        var isUpdating = false

        init(_ parent: ManualTokenTextField) { self.parent = parent }

        @objc func textChanged(_ field: UITextField) {
            guard !isUpdating else { return }
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return false
        }
    }
}
