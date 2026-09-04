import SwiftUI

struct QuestionWizardFooterRow: View {
    let index: Int
    let multiStep: Bool
    let isMulti: Bool
    let isLast: Bool
    let showNext: Bool
    let nextDisabled: Bool
    let submitted: Bool
    let dismissed: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onNext: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if multiStep {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                        Text("Back")
                            .font(.caption)
                    }
                    .foregroundStyle(
                        Theme.mutedForeground(for: colorScheme)
                            .opacity(index == 0 ? 0.4 : 1)
                    )
                    .frame(
                        minWidth: Constants.Accessibility.minimumTapTarget,
                        minHeight: Constants.Accessibility.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
            }
            if !isMulti && !isLast {
                Text("Selecting an option advances")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
            }
            Spacer(minLength: 8)
            Button(action: onSkip) {
                Text("Skip")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(
                        minWidth: Constants.Accessibility.minimumTapTarget,
                        minHeight: Constants.Accessibility.minimumTapTarget)
            }
            .buttonStyle(.plain)
            if showNext {
                Button(action: onNext) {
                    HStack(spacing: 4) {
                        Text(isLast ? "Send" : "Next")
                            .font(.caption.weight(.semibold))
                        Image(systemName: isLast ? "arrow.up" : "arrow.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.primary(for: colorScheme)))
                    .frame(
                        minWidth: Constants.Accessibility.minimumTapTarget,
                        minHeight: Constants.Accessibility.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(nextDisabled || submitted || dismissed)
                .opacity(nextDisabled || submitted || dismissed ? 0.5 : 1)
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}