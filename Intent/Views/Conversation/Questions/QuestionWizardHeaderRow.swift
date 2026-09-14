import SwiftUI

struct QuestionWizardHeaderRow: View {
    let questionCount: Int
    let index: Int
    let isMulti: Bool
    let showsDismiss: Bool
    let dismissed: Bool
    let onIgnore: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private static let progressSegmentSpacing: CGFloat = 4
    private static let multiSelectHorizontalPadding: CGFloat = 7
    private static let multiSelectFillOpacity = 0.8
    private static let minimumContentSpacing: CGFloat = 8
    private static let topPadding: CGFloat = 10
    private static let completedSegmentIncreasedOpacity = 0.7
    private static let completedSegmentOpacity = 0.4
    private static let pendingSegmentIncreasedOpacity = 0.55
    private static let pendingSegmentOpacity = 0.25

    private var multiStep: Bool { questionCount > 1 }

    var body: some View {
        HStack(spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.primary(for: colorScheme))
                .accessibilityHidden(true)
            Text("Questions")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            if multiStep {
                Text("\(index + 1) of \(questionCount)")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                HStack(spacing: Self.progressSegmentSpacing) {
                    ForEach(0..<questionCount, id: \.self) { i in
                        RoundedRectangle(
                            cornerRadius: Constants.Conversation.QuestionWizard.progressSegmentCornerRadius
                        )
                        .fill(segmentColor(i))
                        .frame(
                            width: Constants.Conversation.QuestionWizard.progressSegmentWidth,
                            height: Constants.Conversation.QuestionWizard.progressSegmentHeight
                        )
                    }
                }
            }
            if isMulti {
                Text("Select all that apply")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .padding(.horizontal, Self.multiSelectHorizontalPadding)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.muted(for: colorScheme).opacity(Self.multiSelectFillOpacity)))
            }
            Spacer(minLength: Self.minimumContentSpacing)
            Button(action: onIgnore) {
                Text("Ignore")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(
                        minWidth: Constants.Accessibility.minimumTapTarget,
                        minHeight: Constants.Accessibility.minimumTapTarget
                    )
            }
            .buttonStyle(.plain)
            if showsDismiss {
                QuestionWizardDismissButton(dismissed: dismissed, action: onDismiss)
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
        .padding(.top, Self.topPadding)
    }

    private func segmentColor(_ segment: Int) -> Color {
        if segment < index {
            return Theme.primary(for: colorScheme).opacity(
                colorSchemeContrast == .increased
                    ? Self.completedSegmentIncreasedOpacity
                    : Self.completedSegmentOpacity
            )
        }
        if segment == index { return Theme.primary(for: colorScheme) }
        return Theme.mutedForeground(
            for: colorScheme,
            contrast: colorSchemeContrast
        )
            .opacity(
                colorSchemeContrast == .increased
                    ? Self.pendingSegmentIncreasedOpacity
                    : Self.pendingSegmentOpacity
            )
    }
}
