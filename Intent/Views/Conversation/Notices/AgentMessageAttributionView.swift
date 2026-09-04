import SwiftUI

/// Disclosure header for agent-to-agent messages
/// (`metadata.type == "agent_message"`): agent icon + sender name +
/// "sent a message — {preview}" + chevron. Tapping the trailing region
/// toggles the collapsed body; tapping the sender identity opens that
/// agent's conversation when `onOpenAgent` is provided. Identity and
/// disclosure are sibling tap targets so neither can activate the other —
/// the iOS counterpart of cloudlands-fe's `AgentMessageAttributionHeader`.
struct AgentMessageAttributionView: View {
    let attribution: AgentMessageAttribution
    /// One-line body preview shown next to "sent a message".
    var preview: String = ""
    @Binding var isExpanded: Bool
    /// Tap-through on the sender identity; nil renders it non-interactive.
    var onOpenAgent: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
            if let onOpenAgent {
                Button(action: onOpenAgent) { identity }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(attribution.displayName)'s conversation")
            } else {
                identity
            }

            Button {
                withAnimation(.easeInOut(duration: Constants.Conversation.Attribution.expansionAnimationDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
                    Text("sent a message")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .layoutPriority(1)
                    if !preview.isEmpty {
                        Text("— \(preview)")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(preview.isEmpty
                ? "sent a message"
                : "sent a message: \(preview)")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        }
        .frame(maxWidth: .infinity)
    }

    /// Agent icon + truncated sender name (name is pre-truncated to ~20
    /// chars by the extraction, so it can never crowd out the preview).
    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.Attribution.spacing) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text(attribution.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
        }
        .layoutPriority(1)
    }
}
