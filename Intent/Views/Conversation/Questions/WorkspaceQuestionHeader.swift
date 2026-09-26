import SwiftUI

struct WorkspaceQuestionHeader: View {
    let question: Question
    let onWriteAnswer: () -> Void
    let onCollapse: () -> Void
    let onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(alignment: .top, spacing: Design.Question.buttonSpacing) {
            VStack(alignment: .leading, spacing: Design.Question.titleSpacing) {
                Text(question.header)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .tracking(Design.Typography.compactBodyTracking)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text(question.question)
                    .interFont(Constants.Typography.bodyXS)
                    .tracking(Design.Typography.smallTracking)
                    .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                if question.multiSelect {
                    Text("Select all that apply")
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                }
            }
            actions
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        Menu {
            Button("Write your own answer", action: onWriteAnswer)
            Button("Collapse questions", action: onCollapse)
            if let onDismiss {
                Button("Dismiss questions", role: .destructive, action: onDismiss)
            }
        } label: {
            Image(.more)
                .resizable()
                .frame(width: Design.smallIconSize, height: Design.smallIconSize)
                .frame(width: Design.minimumTapTarget, height: Design.minimumTapTarget)
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Question actions")
        .accessibilityIdentifier("question.actions")
    }
}
