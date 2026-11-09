import SwiftUI

/// Sender navigation and message disclosure remain separate tap targets.
struct AgentMessageAttributionView: View {
    let attribution: AgentMessageAttribution
    var preview: String = ""
    @Binding var isExpanded: Bool
    var onOpenAgent: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var disclosureIconSide: CGFloat = 11

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
                    senderIdentity
                    disclosureButton
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: Constants.Conversation.Attribution.spacing) {
                senderIdentity
                disclosureButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var senderIdentity: some View {
        if let onOpenAgent {
            Button(action: onOpenAgent) {
                identity
                    .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                    .contentShape(Rectangle())
                    .copyContextMenuPassthrough()
            }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Open \(attribution.rawName)'s conversation")
        } else {
            identity
        }
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(.easeInOut(duration: Constants.Conversation.Attribution.expansionAnimationDuration)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
                Text("sent a message")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Image(isExpanded ? .chevronDown : .chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: disclosureIconSide, height: disclosureIconSide)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(preview.isEmpty ? "sent a message" : "sent a message: \(preview)")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }

    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
            Text(attribution.rawName)
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
