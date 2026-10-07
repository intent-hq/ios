import SwiftUI

/// Only the selected card stays mounted. SwiftUI retains the departing card for
/// its transition, then removes its controls from the accessibility tree.
struct QuestionCardPager<Page: View>: View {
    let count: Int
    let index: Int
    let cornerRadius: CGFloat
    var movingForward = true
    @ViewBuilder let page: (Int) -> Page

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Motion = Constants.Conversation.QuestionWizard.Paging

    var body: some View {
        QuestionCardLayout(index: index) {
            if (0..<count).contains(index) {
                VStack(spacing: 0) {
                    page(index)
                }
                .clipShape(.rect(cornerRadius: cornerRadius))
                .layoutValue(key: QuestionCardIndex.self, value: index)
                .id(index)
                .transition(cardTransition)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .animation(
            reduceMotion
                ? .easeOut(duration: Motion.crossfadeDuration)
                : Constants.Conversation.Design.Question.transitionAnimation,
            value: index
        )
    }

    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let gap = Motion.cardSpacing
        return .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading)
                .combined(with: .offset(x: movingForward ? gap : -gap)),
            removal: .move(edge: movingForward ? .leading : .trailing)
                .combined(with: .offset(x: movingForward ? -gap : gap))
        )
    }
}

private struct QuestionCardIndex: LayoutValueKey {
    nonisolated static let defaultValue = 0
}

/// Each page gets the full width and its own natural height. Only the selected
/// page determines the container height; SwiftUI interpolates both the height and
/// placements together, rather than holding a departing ZStack's taller height.
private struct QuestionCardLayout: Layout {
    let index: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        subviews.first { $0[QuestionCardIndex.self] == index }?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let pageProposal = ProposedViewSize(bounds.size)
        for page in subviews {
            page.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: pageProposal
            )
        }
    }
}
