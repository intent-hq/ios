import SwiftUI

/// Measures complete native content, including controls, at the proposed width.
/// The host supplies the remaining question region, not a screen-size breakpoint.
struct WorkspaceQuestionStepView<Footer: View>: View {
    let question: Question
    let index: Int
    let questionCount: Int
    let selectedIndices: [Int]
    let availableHeight: CGFloat
    let onSelect: (Int) -> Void
    let footer: Footer
    var onCollapse: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var collapseIconSide: CGFloat = Constants.Typography.bodyXSEmphasized.size

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        QuestionHeightLimit(maximumHeight: max(0, availableHeight)) {
            ViewThatFits(in: .vertical) {
                if !dynamicTypeSize.isAccessibilitySize {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                }
                scrollingContent
            }
        }
    }

    private var scrollingContent: some View {
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func collapseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text("Collapse questions")
            } icon: {
                Image(.chevronDown)
                    .resizable()
                    .scaledToFit()
                    .frame(width: collapseIconSide, height: collapseIconSide)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(WorkspaceQuestionButtonStyle())
        .accessibilityIdentifier("question.collapse")
    }

    // The fit candidates contain only stateless controls. The free-text editor
    // lives outside this panel, so a layout change cannot replace its responder.
    // The final candidate scrolls the complete content, keeping the footer reachable.
    // Answers stay stacked even when the keyboard reduces the available height.
    private var content: some View {
        VStack(alignment: .leading, spacing: Design.Question.contentSpacing) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Design.Question.titleSpacing) {
                    WorkspaceQuestionHeader(question: question)
                    if questionCount > 1 {
                        Text("Question \(index + 1) of \(questionCount)")
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("question.progress")
                    }
                }
                if let onCollapse {
                    Spacer(minLength: 0)
                    collapseButton(action: onCollapse)
                }
            }
            VStack(alignment: .leading, spacing: Design.Question.footerSpacing) {
                WorkspaceQuestionAnswerCards(
                    options: question.options,
                    selectedIndices: selectedIndices,
                    isMulti: question.multiSelect,
                    onSelect: onSelect
                )
                footer
            }
        }
        .padding(.horizontal, Design.Question.horizontalPadding)
        .padding(.top, Design.Question.topPadding)
        .padding(.bottom, Design.Question.bottomPadding)
    }
}

/// Offers the fit candidates a ceiling without expanding short content to that ceiling.
private struct QuestionHeightLimit: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let height = min(proposal.height ?? maximumHeight, maximumHeight)
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
        return CGSize(width: size.width, height: min(size.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
