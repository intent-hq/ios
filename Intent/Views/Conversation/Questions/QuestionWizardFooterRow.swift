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
    var usesWorkspaceDesign = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var actionIconSide: CGFloat = 12

    private typealias Layout = Constants.Conversation.QuestionWizard.Footer
    private typealias Design = Constants.Conversation.Design

    var body: some View {
        if usesWorkspaceDesign {
            workspaceFooter
        } else {
            legacyFooter
        }
    }

    private var workspaceFooter: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: Design.Question.buttonSpacing))
            : AnyLayout(HStackLayout(spacing: Design.Question.buttonSpacing))
        return layout {
            if multiStep {
                Button("Back", action: onBack)
                    .buttonStyle(WorkspaceQuestionButtonStyle())
                    .disabled(index == 0)
                    .accessibilityIdentifier("question.back")
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            Button("Skip", action: onSkip)
                .buttonStyle(WorkspaceQuestionButtonStyle())
                .accessibilityIdentifier("question.skip")
            if showNext {
                Button(isLast ? "Send" : "Next", action: onNext)
                    .buttonStyle(WorkspaceQuestionButtonStyle(primary: true))
                    .disabled(nextDisabled)
                    .accessibilityIdentifier("question.next")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(submitted || dismissed)
    }

    private var legacyFooter: some View {
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
                Image(.chevronLeft)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSide, height: actionIconSide)
                    .accessibilityHidden(true)
                Text("Back")
                    .interFont(Constants.Typography.subtextXXS)
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
        .buttonStyle(IntentContentButtonStyle())
        .disabled(index == 0)
    }

    private var selectionInstruction: some View {
        Text("Selecting an option advances")
            .interFont(Constants.Typography.subtextXXS)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.instructionOpacity))
    }

    private var skipButton: some View {
        Button(action: onSkip) {
            Text("Skip")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(IntentContentButtonStyle())
    }

    private var nextButton: some View {
        Button(action: onNext) {
            HStack(spacing: Layout.buttonLabelSpacing) {
                Text(isLast ? "Send" : "Next")
                    .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                Image(isLast ? .arrowUp : .arrowRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSide, height: actionIconSide)
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
        .buttonStyle(IntentContentButtonStyle())
        .disabled(nextDisabled || submitted || dismissed)
        .opacity(nextDisabled || submitted || dismissed ? Layout.nextButtonDisabledOpacity : 1)
    }
}
