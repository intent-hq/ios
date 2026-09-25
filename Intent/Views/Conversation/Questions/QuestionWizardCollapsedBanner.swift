import SwiftUI

struct QuestionWizardCollapsedBanner: View {
    let questionCount: Int
    let showsDismiss: Bool
    let dismissed: Bool
    let onExpand: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.QuestionWizard.CollapsedBanner

    var body: some View {
        HStack(spacing: 0) {
            expandButton
            if showsDismiss {
                QuestionWizardDismissButton(dismissed: dismissed, action: onDismiss)
                    .padding(.trailing, Layout.dismissButtonTrailingPadding)
            }
        }
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            HStack(spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.primary(for: colorScheme))
                Text("Questions")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text("\(questionCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .padding(.horizontal, Layout.countBadgeHorizontalPadding)
                    .padding(.vertical, Layout.countBadgeVerticalPadding)
                    .background(Capsule().fill(Theme.primary(for: colorScheme).opacity(Layout.badgeFillOpacity)))
                    .overlay(
                        Capsule().strokeBorder(
                            Theme.primary(for: colorScheme).opacity(Layout.countBadgeBorderOpacity),
                            lineWidth: Layout.countBadgeBorderWidth
                        )
                    )
                Spacer(minLength: Layout.minimumContentSpacing)
                Text("Tap to expand")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
            .padding(.vertical, Layout.verticalPadding)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand questions")
        .accessibilityValue("\(questionCount) questions")
    }
}

struct QuestionWizardDismissButton: View {
    let dismissed: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.QuestionWizard.DismissButton

    var body: some View {
        Button(action: action) {
            Text("Dismiss")
                .font(.caption)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.vertical, Layout.verticalPadding)
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dismissed)
        .opacity(dismissed ? Layout.disabledOpacity : 1)
    }
}
