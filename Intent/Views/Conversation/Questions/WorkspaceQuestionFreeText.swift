import SwiftUI

/// Lets the native field lay out its prompt, caret, and multiline answer together.
struct WorkspaceQuestionFreeText: View {
    @Binding var text: String
    let focused: FocusState<Bool>.Binding
    let isLast: Bool
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: Design.Question.buttonSpacing) {
            TextField(
                "Message",
                text: $text,
                prompt: Text("Message")
                    .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast)),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .interFont(Constants.Typography.bodyS)
            .foregroundStyle(Design.Palette.foreground(for: colorScheme))
            .lineLimit(1...Constants.Conversation.QuestionWizard.freeTextMaximumLineCount)
            .frame(minHeight: Design.minimumTapTarget)
            .focused(focused)
            .submitLabel(.return)
            .accessibilityLabel("Type your own answer…")
            .accessibilityIdentifier("question.freeText")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusButton
            } else {
                submitButton
            }
        }
        .padding(.leading, Design.Composer.leadingPadding)
        .padding(.trailing, Design.Composer.activeTrailingPadding)
        .padding(.vertical, (Design.Composer.minimumHeight - Design.minimumTapTarget) / 2)
        .frame(minHeight: Design.Composer.minimumHeight)
        .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.cornerRadius))
        .onChange(of: text) { _, _ in onTextChange() }
    }

    private var submitButton: some View {
        Button(action: onSubmit) {
            Image(.arrowRight)
                .resizable()
                .scaledToFit()
                .frame(width: Design.iconSize, height: Design.iconSize)
                .accessibilityHidden(true)
        }
        .buttonStyle(WorkspaceQuestionButtonStyle(primary: true))
        .accessibilityLabel(isLast ? "Send" : "Next")
        .accessibilityIdentifier("question.freeText.submit")
    }

    private var focusButton: some View {
        Button { focused.wrappedValue = true } label: {
            Image(.addIcon)
                .resizable()
                .scaledToFit()
                .frame(width: Design.iconSize, height: Design.iconSize)
                .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                .frame(width: Design.minimumTapTarget, height: Design.minimumTapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Write your own answer")
    }
}
