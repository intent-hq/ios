import SwiftUI

struct WorkspaceQuestionHeader: View {
    let question: Question

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
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
            if let explanation = question.explanation, !explanation.isEmpty {
                Text(explanation)
                    .interFont(Constants.Typography.bodyXS)
                    .tracking(Design.Typography.smallTracking)
                    .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    .accessibilityIdentifier("question.explanation")
            }
            if question.multiSelect {
                Text("Select all that apply")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            }
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
}
