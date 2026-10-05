import SwiftUI

struct QuestionWizardCollapsedBanner: View {
    let questionCount: Int
    let showsDismiss: Bool
    let dismissed: Bool
    let onExpand: () -> Void
    let onDismiss: () -> Void
    var usesWorkspaceDesign = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var questionIconSide: CGFloat = 12

    private typealias Layout = Constants.Conversation.QuestionWizard.CollapsedBanner
    private typealias Design = Constants.Conversation.Design

    var body: some View {
        if usesWorkspaceDesign {
            workspaceBanner
        } else {
            legacyBanner
        }
    }

    private var workspaceBanner: some View {
        VStack(alignment: .leading, spacing: Design.Question.notificationSpacing) {
            Text("Agent has \(questionCount) questions")
                .interFont(Constants.Typography.bodySEmphasized)
                .tracking(Design.Typography.compactBodyTracking)
                .foregroundStyle(Design.Palette.foreground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Design.Question.buttonSpacing))
                : AnyLayout(HStackLayout(spacing: Design.Question.buttonSpacing))
            layout {
                if showsDismiss {
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(WorkspaceQuestionButtonStyle(fillsWidth: true))
                        .accessibilityIdentifier("question.dismiss")
                }
                Button("Answer", action: onExpand)
                    .buttonStyle(WorkspaceQuestionButtonStyle(primary: true, fillsWidth: true))
                    .accessibilityIdentifier("question.answer")
            }
            .disabled(dismissed)
        }
        .padding(.horizontal, Design.Question.horizontalPadding)
        .padding(.top, Design.Question.topPadding)
        .padding(.bottom, Design.Question.bottomPadding)
    }

    private var legacyBanner: some View {
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
                Image(.questionCircle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: questionIconSide, height: questionIconSide)
                    .foregroundStyle(Theme.primary(for: colorScheme))
                Text("Questions")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text("\(questionCount)")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
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
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
            .padding(.vertical, Layout.verticalPadding)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
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
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.vertical, Layout.verticalPadding)
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(dismissed)
        .opacity(dismissed ? Layout.disabledOpacity : 1)
    }
}
