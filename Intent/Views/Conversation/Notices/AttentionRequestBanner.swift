import SwiftUI

/// Kind-flavored conversation-header banner for a pending attention request.
struct AttentionRequestBanner: View {
    let attention: PendingAttentionRequest
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private static let contentSpacing: CGFloat = 8
    private static let detailSpacing: CGFloat = 1
    private static let labelSpacing: CGFloat = 6
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 8
    private static let backgroundOpacity: Double = 0.1
    private static let increasedContrastBackgroundOpacity: Double = 0.18
    private static let dividerOpacity: Double = 0.45
    private static let increasedContrastDividerOpacity: Double = 1
    private static let dividerHeight: CGFloat = 1
    private static let increasedContrastDividerHeight: CGFloat = 2

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            Image(systemName: attention.kind.systemImage)
                .font(.subheadline)
                .foregroundStyle(attention.kind.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Self.detailSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: Self.labelSpacing) {
                    Text(attention.kind.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    if let raisedAt = attention.raisedAt {
                        (Text(min(raisedAt, Date()), style: .relative) + Text(" ago"))
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(
                                for: colorScheme,
                                contrast: colorSchemeContrast
                            ))
                    }
                }

                if let reason = attention.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(
                            for: colorScheme,
                            contrast: colorSchemeContrast
                        ))
                        .lineLimit(Constants.Conversation.AttentionRequest.reasonLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(attention.kind.color.opacity(colorSchemeContrast == .increased
            ? Self.increasedContrastBackgroundOpacity
            : Self.backgroundOpacity))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(attention.kind.color.opacity(colorSchemeContrast == .increased
                    ? Self.increasedContrastDividerOpacity
                    : Self.dividerOpacity))
                .frame(height: colorSchemeContrast == .increased
                    ? Self.increasedContrastDividerHeight
                    : Self.dividerHeight)
        }
    }
}
