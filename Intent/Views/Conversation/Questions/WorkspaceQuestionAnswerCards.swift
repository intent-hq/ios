import SwiftUI

struct WorkspaceQuestionAnswerCards: View {
    let options: [QuestionOption]
    let selectedIndices: [Int]
    let isMulti: Bool
    let horizontal: Bool
    let availableHeight: CGFloat
    let onSelect: (Int) -> Void

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        if horizontal {
            QuestionCarouselFitLayout(
                standardHeight: Design.Question.carouselAnswerHeight,
                availableHeight: availableHeight
            ) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Design.Question.answerSpacing) {
                        cards
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: Design.Question.answerSpacing) {
                cards
            }
        }
    }

    private var cards: some View {
        // Options are immutable for this mounted question and have no wire ID;
        // their index is also the existing selection contract, including duplicate labels.
        let answerCards = options.indices.map { index in
            WorkspaceQuestionAnswerCard(
                index: index,
                option: options[index],
                selected: selectedIndices.contains(index),
                isMulti: isMulti,
                horizontal: horizontal
            ) {
                onSelect(index)
            }
        }
        // SwiftUI can request a ForEach row off-main during fit/transition work.
        // Transfer only prepared view values; actions and environment reads stay
        // in the main-actor card, not in the framework's row-provider callback.
        return ForEach(answerCards.indices, id: \.self) { @Sendable index in
            answerCards[index]
        }
    }
}

private struct WorkspaceQuestionAnswerCard: View {
    let index: Int
    let option: QuestionOption
    let selected: Bool
    let isMulti: Bool
    let horizontal: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        let widthFraction = Constants.Conversation.QuestionWizard.Workspace.carouselWidthFraction
        Button(action: onSelect) {
            cardText
            .tracking(Design.Typography.smallTracking)
            .foregroundStyle(Design.Palette.foreground(for: colorScheme))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Design.Question.answerPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: horizontal ? Design.Question.carouselAnswerHeight : Design.minimumTapTarget,
                alignment: horizontal ? .topLeading : .leading
            )
            .background(selected ? Design.Palette.raisedSurface(for: colorScheme) : .clear)
            .clipShape(.rect(cornerRadius: Design.innerCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Design.innerCornerRadius)
                    .strokeBorder(
                        selected && contrast != .increased
                            ? .clear : Design.Palette.border(for: colorScheme, contrast: contrast),
                        lineWidth: Design.Question.borderWidth
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.description ?? "")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .containerRelativeFrame(horizontal ? .horizontal : []) { @Sendable length, _ in
            length * widthFraction
        }
        .accessibilityIdentifier("question.option.\(index)")
    }

    private var cardText: some View {
        VStack(alignment: .leading, spacing: Design.Question.answerTextSpacing) {
            HStack(alignment: .top, spacing: Design.Question.buttonSpacing) {
                Text(option.label)
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isMulti {
                    Image(.check)
                        .resizable()
                        .frame(width: Design.smallIconSize, height: Design.smallIconSize)
                        .opacity(selected ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            if let description = option.description {
                Text(description)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            }
        }
    }
}

/// Keep natural text measurement so no option (including off-screen ones) is clipped.
/// Reject an oversized carousel in the step's ViewThatFits, instead of growing the
/// standard height or keeping stateful measurements that can oscillate between candidates.
private struct QuestionCarouselFitLayout: Layout {
    let standardHeight: CGFloat
    let availableHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let carousel = subviews.first else { return .zero }
        var size = carousel.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        if size.height > standardHeight {
            size.height = max(size.height, availableHeight + 1)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}
