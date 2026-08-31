import SwiftUI

/// Kind-flavored conversation-header banner for a pending attention request.
struct AttentionRequestBanner: View {
    let attention: PendingAttentionRequest
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attention.kind.systemImage)
                .font(.subheadline)
                .foregroundStyle(attention.kind.color)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(attention.kind.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    if let raisedAt = attention.raisedAt {
                        (Text(min(raisedAt, Date()), style: .relative) + Text(" ago"))
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                }

                if let reason = attention.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(attention.kind.color.opacity(0.1))
    }
}