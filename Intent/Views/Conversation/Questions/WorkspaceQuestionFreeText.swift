import SwiftUI

/// Uses the same multiline editor and Return policy as the existing wizard.
struct WorkspaceQuestionFreeText: View {
    @Binding var text: String
    @Binding var focused: Bool
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var height = QuestionStepView.clampedFreeTextHeight(
        0, lineHeight: QuestionStepView.freeTextLineHeight
    )

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: Design.Question.buttonSpacing) {
            SubmittableTextView(
                text: $text,
                isFocused: $focused,
                onSubmit: onSubmit,
                onHeightChange: { contentHeight in
                    height = QuestionStepView.clampedFreeTextHeight(
                        contentHeight, lineHeight: QuestionStepView.freeTextLineHeight
                    )
                },
                hoverCornerRadius: Design.cornerRadius,
                accessibilityLabel: "Type your own answer…",
                textColor: UIColor(Design.Palette.foreground(for: colorScheme))
            )
            .frame(height: max(height, Design.minimumTapTarget))
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text("Message")
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                        .padding(.leading, Constants.Conversation.QuestionWizard.Step.lineFragmentPadding)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            focusButton
        }
        .padding(.leading, Design.Composer.leadingPadding - Constants.Conversation.QuestionWizard.Step.lineFragmentPadding)
        .padding(.trailing, Design.Composer.activeTrailingPadding)
        .frame(minHeight: Design.Composer.minimumHeight)
        .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.cornerRadius))
        .onChange(of: text) { _, _ in onTextChange() }
    }

    private var focusButton: some View {
        Button { focused = true } label: {
            Image(.addIcon)
                .resizable()
                .scaledToFit()
                .frame(width: Design.iconSize, height: Design.iconSize)
                .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                .frame(width: Design.minimumTapTarget, height: Design.minimumTapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write your own answer")
    }
}
