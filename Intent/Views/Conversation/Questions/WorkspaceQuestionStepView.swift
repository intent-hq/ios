import SwiftUI

/// Measures complete native content, including controls, at the proposed width.
/// The host supplies the remaining question region, not a screen-size breakpoint.
struct WorkspaceQuestionStepView<Footer: View>: View {
    let question: Question
    let index: Int
    let questionCount: Int
    let selectedIndices: [Int]
    @Binding var freeText: String
    let availableHeight: CGFloat
    let onSelect: (Int) -> Void
    let onSubmit: () -> Void
    let onTextChange: () -> Void
    let onCollapse: () -> Void
    let onDismiss: (() -> Void)?
    let footer: Footer

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var writesAnswer = false

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        ViewThatFits(in: .vertical) {
            if !dynamicTypeSize.isAccessibilitySize, !writesAnswer, freeText.isEmpty {
                content(horizontal: false)
                    .fixedSize(horizontal: false, vertical: true)
                content(horizontal: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                content(horizontal: false)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: max(0, availableHeight), alignment: .bottom)
    }

    // The two fit candidates contain only stateless controls. Drafts belong to
    // QuestionWizardView; the editor mounts only in the vertical fallback so a
    // keyboard resize cannot swap its native first responder into another branch.
    private func content(horizontal: Bool) -> some View {
        VStack(alignment: .leading, spacing: Design.Question.contentSpacing) {
            WorkspaceQuestionHeader(
                question: question,
                onWriteAnswer: { writesAnswer = true },
                onCollapse: onCollapse,
                onDismiss: onDismiss
            )
            if questionCount > 1 {
                Text("Question \(index + 1) of \(questionCount)")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    .accessibilityIdentifier("question.progress")
            }
            WorkspaceQuestionAnswerCards(
                options: question.options,
                selectedIndices: selectedIndices,
                isMulti: question.multiSelect,
                horizontal: horizontal,
                onSelect: onSelect
            )
            if writesAnswer || !freeText.isEmpty {
                WorkspaceQuestionFreeText(
                    text: $freeText,
                    onSubmit: onSubmit,
                    onTextChange: onTextChange
                )
            }
            footer
        }
        .padding(.horizontal, Design.Question.horizontalPadding)
        .padding(.top, Design.Question.topPadding)
        .padding(.bottom, Design.Question.bottomPadding)
    }
}
