import SwiftUI

/// Uses the same multiline editor and Return policy as the existing wizard.
struct WorkspaceQuestionFreeText: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var focused = false
    @State private var height = QuestionStepView.clampedFreeTextHeight(
        0, lineHeight: QuestionStepView.freeTextLineHeight
    )

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Question.buttonSpacing) {
            Text("Your answer")
                .interFont(Constants.Typography.bodyXSEmphasized)
                .foregroundStyle(Design.Palette.foreground(for: colorScheme))
            SubmittableTextView(
                text: $text,
                isFocused: $focused,
                onSubmit: onSubmit,
                onHeightChange: { contentHeight in
                    height = QuestionStepView.clampedFreeTextHeight(
                        contentHeight, lineHeight: QuestionStepView.freeTextLineHeight
                    )
                },
                hoverCornerRadius: Design.innerCornerRadius,
                accessibilityLabel: "Type your own answer…"
            )
            .frame(height: max(height, Design.minimumTapTarget))
            .padding(Design.Question.buttonSpacing)
            .background(Design.Palette.raisedSurface(for: colorScheme))
            .clipShape(.rect(cornerRadius: Design.innerCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Design.innerCornerRadius)
                    .strokeBorder(
                        Design.Palette.border(for: colorScheme, contrast: contrast),
                        lineWidth: Design.Question.borderWidth
                    )
            }
        }
        .onChange(of: text) { _, _ in onTextChange() }
    }
}
