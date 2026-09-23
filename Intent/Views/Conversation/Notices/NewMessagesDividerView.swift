import SwiftUI

/// Presentation-only "New messages" unread marker (FE parity:
/// NewMessagesDivider.svelte) — hairline, envelope + caption, hairline.
/// Never part of the transcript; rendered by ConversationView directly
/// after the session's latched divider anchor message.
struct NewMessagesDividerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private typealias Layout = Constants.Conversation.NewMessagesDivider

    var body: some View {
        HStack(spacing: Layout.contentSpacing) {
            hairline
            HStack(spacing: Layout.labelSpacing) {
                Image(systemName: "envelope")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.iconOpacity))
                Text("New messages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, Layout.labelHorizontalPadding)
            .layoutPriority(1)
            hairline
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: Layout.hairlinePixelHeight / max(displayScale, Layout.minimumDisplayScale))
            .frame(minWidth: Layout.minimumLineWidth, maxWidth: .infinity)
    }
}
