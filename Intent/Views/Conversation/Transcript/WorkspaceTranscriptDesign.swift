import SwiftUI

extension EnvironmentValues {
    /// Opt in only at the approved workspace transcript root. Shared callers keep their existing UI.
    @Entry var workspaceTranscriptDesign = false
}

/// Measures a trailing bubble against its actual proposal, without fixed heights or screen-size reads.
struct WorkspaceUserBubbleLayout: Layout {
    var usesFullWidth: Bool
    var layoutDirection: LayoutDirection

    private func bubbleProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        let fraction = usesFullWidth ? 1 : Constants.Conversation.Design.Transcript.bubbleMaximumWidthFraction
        return ProposedViewSize(width: proposal.width.map { $0 * fraction }, height: nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let size = bubble.sizeThatFits(bubbleProposal(proposal))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let bubble = subviews.first else { return }
        let childProposal = bubbleProposal(ProposedViewSize(width: bounds.width, height: nil))
        let size = bubble.sizeThatFits(childProposal)
        let origin = CGPoint(
            x: layoutDirection == .rightToLeft ? bounds.minX : bounds.maxX - size.width,
            y: bounds.minY
        )
        bubble.place(at: origin, proposal: childProposal)
    }
}

struct WorkspaceTranscriptDisclosure: View {
    let isExpanded: Bool

    var body: some View {
        Image(isExpanded ? .conversationChevronUp : .conversationChevronRight)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(
                width: Constants.Conversation.Design.toolIconSize,
                height: Constants.Conversation.Design.toolIconSize
            )
            .accessibilityHidden(true)
    }
}
