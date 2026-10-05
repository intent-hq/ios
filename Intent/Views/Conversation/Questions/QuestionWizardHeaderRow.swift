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

    private typealias Layout = Constants.Conversation.QuestionWizard.Header

    private var multiStep: Bool { questionCount > 1 }

    var body: some View {
        HStack(spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
            title
            if multiStep {
                progress
            }
            if isMulti {
                multiSelectBadge
            }
            Spacer(minLength: Layout.minimumContentSpacing)
            ignoreButton
            if showsDismiss {
                QuestionWizardDismissButton(dismissed: dismissed, action: onDismiss)
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
        .padding(.top, Layout.topPadding)
    }

    private var title: some View {
        Group {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.primary(for: colorScheme))
                .accessibilityHidden(true)
            Text("Questions")
                .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
        }
    }

    private var progress: some View {
        Group {
            Text("\(index + 1) of \(questionCount)")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            HStack(spacing: Layout.progressSegmentSpacing) {
                ForEach(0..<questionCount, id: \.self) { segment in
                    RoundedRectangle(cornerRadius: Constants.Conversation.QuestionWizard.progressSegmentCornerRadius)
                        .fill(segmentColor(segment))
                        .frame(
                            width: Constants.Conversation.QuestionWizard.progressSegmentWidth,
                            height: Constants.Conversation.QuestionWizard.progressSegmentHeight
                        )
                }
            }
        }
    }

    private var multiSelectBadge: some View {
        Text("Select all that apply")
            .interFont(Constants.Typography.subtextXXS)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .padding(.horizontal, Layout.multiSelectHorizontalPadding)
            .padding(.vertical, Layout.multiSelectVerticalPadding)
            .background(Capsule().fill(Theme.muted(for: colorScheme).opacity(Layout.multiSelectFillOpacity)))
    }

    private var ignoreButton: some View {
        Button(action: onIgnore) {
            Text("Ignore")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(IntentContentButtonStyle())
    }

    private func segmentColor(_ segment: Int) -> Color {
        if segment < index {
            return Theme.primary(for: colorScheme).opacity(
                colorSchemeContrast == .increased
                    ? Layout.completedSegmentIncreasedOpacity
                    : Layout.completedSegmentOpacity
            )
        }
        if segment == index { return Theme.primary(for: colorScheme) }
        return Theme.mutedForeground(
            for: colorScheme,
            contrast: colorSchemeContrast
        )
            .opacity(
                colorSchemeContrast == .increased
                    ? Layout.pendingSegmentIncreasedOpacity
                    : Layout.pendingSegmentOpacity
            )
    }
}
