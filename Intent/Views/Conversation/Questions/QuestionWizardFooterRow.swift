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

    private typealias Layout = Constants.Conversation.QuestionWizard.Footer

    var body: some View {
        HStack(spacing: Layout.contentSpacing) {
            if multiStep {
                backButton
            }
            if !isMulti, !isLast {
                selectionInstruction
            }
            Spacer(minLength: Layout.minimumContentSpacing)
            skipButton
            if showNext {
                nextButton
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
        .padding(.top, Layout.topPadding)
        .padding(.bottom, Layout.bottomPadding)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: Layout.buttonLabelSpacing) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Back")
                    .font(.caption)
            }
            .foregroundStyle(
                Theme.mutedForeground(for: colorScheme)
                    .opacity(index == 0 ? Layout.disabledBackOpacity : 1)
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
            .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.instructionOpacity))
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
            HStack(spacing: Layout.buttonLabelSpacing) {
                Text(isLast ? "Send" : "Next")
                    .font(.caption.weight(.semibold))
                Image(systemName: isLast ? "arrow.up" : "arrow.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Layout.nextButtonHorizontalPadding)
            .padding(.vertical, Layout.nextButtonVerticalPadding)
            .background(Capsule().fill(Theme.primary(for: colorScheme)))
            .frame(
                minWidth: Constants.Accessibility.minimumTapTarget,
                minHeight: Constants.Accessibility.minimumTapTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(nextDisabled || submitted || dismissed)
        .opacity(nextDisabled || submitted || dismissed ? Layout.nextButtonDisabledOpacity : 1)
    }
}
