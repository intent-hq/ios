import SwiftUI

/// Presentation-only "New messages" unread marker (FE parity:
/// NewMessagesDivider.svelte) — hairline, envelope + caption, hairline.
/// Never part of the transcript; rendered by ConversationView directly
/// after the session's latched divider anchor message.
struct NewMessagesDividerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 8) {
            hairline
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.7))
                Text("New messages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .layoutPriority(1)
            hairline
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: 1 / max(displayScale, 1))
            .frame(minWidth: 16, maxWidth: .infinity)
    }
}
