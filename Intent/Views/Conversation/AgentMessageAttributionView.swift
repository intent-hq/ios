import SwiftUI

/// Compact attribution header for agent-to-agent messages
/// (`metadata.type == "agent_message"`): agent icon + sender name +
/// "sent a message". Non-interactive — the iOS counterpart of
/// cloudlands-fe's `AgentMessageAttributionHeader` (minus tap-through
/// to the sender's conversation).
struct AgentMessageAttributionView: View {
    let attribution: AgentMessageAttribution
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text(attribution.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
            Text("sent a message")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }
}
