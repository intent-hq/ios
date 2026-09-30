import SwiftUI

/// Disclosure header for agent-to-agent messages
/// (`metadata.type == "agent_message"`): agent icon + sender name +
/// "sent a message — {preview}" + chevron. Tapping the trailing region
/// toggles the collapsed body; tapping the sender identity opens that
/// agent's conversation when `onOpenAgent` is provided. Identity and
/// disclosure are sibling tap targets so neither can activate the other —
/// the iOS counterpart of cloudlands-fe's `AgentMessageAttributionHeader`.
struct AgentMessageAttributionView: View {
    private static let minimumSenderWidth: CGFloat = 44
    let attribution: AgentMessageAttribution
    /// One-line body preview shown next to "sent a message".
    var preview: String = ""
    @Binding var isExpanded: Bool
    /// Tap-through on the sender identity; nil renders it non-interactive.
    var onOpenAgent: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if workspaceDesign {
                ViewThatFits(in: .horizontal) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
                            senderIdentity
                                .frame(
                                    minWidth: Self.minimumSenderWidth,
                                    idealWidth: Self.minimumSenderWidth,
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                            // Drop the optional preview before squeezing the disclosure phrase.
                            disclosureButton(singleLine: true)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(2)
                        }
                    }
                    VStack(alignment: .leading, spacing: Constants.Conversation.Attribution.spacing) {
                        senderIdentity
                        disclosureButton(singleLine: false)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
                    senderIdentity
                    disclosureButton(singleLine: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var senderIdentity: some View {
        if let onOpenAgent {
            Button(action: onOpenAgent) { identity }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(attribution.displayName)'s conversation")
        } else {
            identity
        }
    }

    private func disclosureButton(singleLine: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: Constants.Conversation.Attribution.expansionAnimationDuration)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
                Text("sent a message")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .layoutPriority(1)
                    .fixedSize(horizontal: singleLine, vertical: workspaceDesign)
                if !preview.isEmpty, !singleLine {
                    Text("— \(preview)")
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .fixedSize(horizontal: workspaceDesign, vertical: workspaceDesign)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preview.isEmpty ? "sent a message" : "sent a message: \(preview)")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }

    /// The workspace name yields space to the disclosure before truncating its phrase.
    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
            Text(attribution.displayName)
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
        }
        .layoutPriority(workspaceDesign ? 0 : 1)
    }
}
