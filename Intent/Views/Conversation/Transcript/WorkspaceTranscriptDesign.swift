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

struct WorkspaceThinkingView: View {
    let text: String
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Transcript.toolRowSpacing) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: Constants.Conversation.ToolCall.expansionAnimationDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                WorkspaceThinkingLabel(title: "Thinking", isExpanded: isExpanded)
                    .frame(minHeight: Design.minimumTapTarget)
                    .contentShape(Rectangle())
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                Text(text)
                    .interFont(Constants.Typography.bodyS.withFace(.italic))
                    .tracking(Design.Typography.bodyTracking)
                    .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Design.Transcript.expandedContentIndent)
            }
        }
    }
}

/// Shared alignment for persisted thinking disclosures and the live activity row.
struct WorkspaceThinkingLabel: View {
    let title: LocalizedStringKey
    var isExpanded = false
    var showsDisclosure = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: Design.Transcript.disclosureSpacing) {
            HStack(spacing: Design.Transcript.toolLabelSpacing) {
                Image(.conversationThinking)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                    .accessibilityHidden(true)
                Text(title)
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsDisclosure {
                WorkspaceTranscriptDisclosure(isExpanded: isExpanded)
            }
        }
        .foregroundStyle(isExpanded ? Design.Palette.foreground(for: colorScheme)
            : Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
    }
}
