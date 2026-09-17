import SwiftUI

/// Presentation-only "New messages" unread marker (FE parity:
/// NewMessagesDivider.svelte) — hairline, envelope + caption, hairline.
/// Never part of the transcript; rendered by ConversationView directly
/// after the session's latched divider anchor message.
struct NewMessagesDividerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private static let contentSpacing: CGFloat = 8
    private static let labelSpacing: CGFloat = 6
    private static let iconOpacity: Double = 0.7
    private static let labelHorizontalPadding: CGFloat = 4
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4
    private static let hairlinePixelHeight: CGFloat = 1
    private static let minimumDisplayScale: CGFloat = 1
    private static let minimumLineWidth: CGFloat = 16

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            hairline
            HStack(spacing: Self.labelSpacing) {
                Image(systemName: "envelope")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Self.iconOpacity))
                Text("New messages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, Self.labelHorizontalPadding)
            .layoutPriority(1)
            hairline
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: Self.hairlinePixelHeight / max(displayScale, Self.minimumDisplayScale))
            .frame(minWidth: Self.minimumLineWidth, maxWidth: .infinity)
    }
}
