import SwiftUI

struct QuestionWizardCollapsedBanner: View {
    let questionCount: Int
    let showsDismiss: Bool
    let dismissed: Bool
    let onExpand: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
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
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.primary(for: colorScheme).opacity(0.12)))
                        .overlay(
                            Capsule().strokeBorder(
                                Theme.primary(for: colorScheme).opacity(0.35), lineWidth: 1)
                        )
                    Spacer(minLength: 8)
                    Text("Tap to expand")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
                .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
                .padding(.vertical, 9)
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand questions")
            .accessibilityValue("\(questionCount) questions")
            if showsDismiss {
                QuestionWizardDismissButton(dismissed: dismissed, action: onDismiss)
                    .padding(.trailing, 8)
            }
        }
    }
}

struct QuestionWizardDismissButton: View {
    let dismissed: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text("Dismiss")
                .font(.caption)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dismissed)
        .opacity(dismissed ? 0.5 : 1)
    }
}