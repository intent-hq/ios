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

    private static let contentSpacing: CGFloat = 8
    private static let buttonLabelSpacing: CGFloat = 4
    private static let disabledBackOpacity = 0.4
    private static let instructionOpacity = 0.6
    private static let minimumContentSpacing: CGFloat = 8
    private static let nextButtonHorizontalPadding: CGFloat = 12
    private static let nextButtonVerticalPadding: CGFloat = 6
    private static let bottomPadding: CGFloat = 12

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            if multiStep {
                backButton
            }
            if !isMulti, !isLast {
                selectionInstruction
            }
            Spacer(minLength: Self.minimumContentSpacing)
            skipButton
            if showNext {
                nextButton
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
        .padding(.top, 2)
        .padding(.bottom, Self.bottomPadding)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: Self.buttonLabelSpacing) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Back")
                    .font(.caption)
            }
            .foregroundStyle(
                Theme.mutedForeground(for: colorScheme)
                    .opacity(index == 0 ? Self.disabledBackOpacity : 1)
            )
            .frame(
                minWidth: Constants.Accessibility.minimumTapTarget,
                minHeight: Constants.Accessibility.minimumTapTarget
            )
        }
        .buttonStyle(.plain)
        .disabled(index == 0)
    }

    private var selectionInstruction: some View {
        Text("Selecting an option advances")
            .font(.caption)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Self.instructionOpacity))
    }

    private var skipButton: some View {
        Button(action: onSkip) {
            Text("Skip")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(.plain)
    }

    private var nextButton: some View {
        Button(action: onNext) {
            HStack(spacing: Self.buttonLabelSpacing) {
                Text(isLast ? "Send" : "Next")
                    .font(.caption.weight(.semibold))
                Image(systemName: isLast ? "arrow.up" : "arrow.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Self.nextButtonHorizontalPadding)
            .padding(.vertical, Self.nextButtonVerticalPadding)
            .background(Capsule().fill(Theme.primary(for: colorScheme)))
            .frame(
                minWidth: Constants.Accessibility.minimumTapTarget,
                minHeight: Constants.Accessibility.minimumTapTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(nextDisabled || submitted || dismissed)
        .opacity(nextDisabled || submitted || dismissed ? 0.5 : 1)
    }
}
