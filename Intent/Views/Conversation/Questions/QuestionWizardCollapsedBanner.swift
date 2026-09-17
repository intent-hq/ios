import SwiftUI

struct QuestionWizardCollapsedBanner: View {
    let questionCount: Int
    let showsDismiss: Bool
    let dismissed: Bool
    let onExpand: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let countBadgeHorizontalPadding: CGFloat = 7
    private static let badgeFillOpacity = 0.12
    private static let countBadgeBorderOpacity = 0.35
    private static let minimumContentSpacing: CGFloat = 8
    private static let verticalPadding: CGFloat = 9
    private static let dismissButtonTrailingPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            expandButton
            if showsDismiss {
                QuestionWizardDismissButton(dismissed: dismissed, action: onDismiss)
                    .padding(.trailing, Self.dismissButtonTrailingPadding)
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
                    .padding(.horizontal, Self.countBadgeHorizontalPadding)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.primary(for: colorScheme).opacity(Self.badgeFillOpacity)))
                    .overlay(
                        Capsule().strokeBorder(
                            Theme.primary(for: colorScheme).opacity(Self.countBadgeBorderOpacity),
                            lineWidth: 1
                        )
                    )
                Spacer(minLength: Self.minimumContentSpacing)
                Text("Tap to expand")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
            .padding(.vertical, Self.verticalPadding)
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

    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 4

    var body: some View {
        Button(action: action) {
            Text("Dismiss")
                .font(.caption)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dismissed)
        .opacity(dismissed ? 0.5 : 1)
    }
}
