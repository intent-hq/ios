import SwiftUI

/// Compact chip for an `@context[...]` mention in a user message: provider
/// icon + truncated decoded title on a muted rounded background — the iOS
/// counterpart of cloudlands-fe's `ContextChip.svelte`. Chips whose `url`
/// passes the `ExternalLink` http/https allowlist open it in the browser;
/// chips without one (or with a rejected scheme) are static.
struct ContextMentionChipView: View {
    let mention: ContextMention
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) private var openURL

    private static let labelSpacing: CGFloat = 4
    private static let iconOpacity: Double = 0.6
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 3
    private static let backgroundOpacity: Double = 0.7
    private static let cornerRadius: CGFloat = 5

    var body: some View {
        if let url = ExternalLink.url(from: mention.url) {
            Button {
                openURL(url)
            } label: {
                chipLabel
            }
            .buttonStyle(.plain)
        } else {
            chipLabel
        }
    }

    private var chipLabel: some View {
        HStack(spacing: Self.labelSpacing) {
            Image(systemName: Self.iconName(for: mention.provider))
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Self.iconOpacity))
                .accessibilityHidden(true)
            Text(Self.displayTitle(mention.title))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(Theme.muted(for: colorScheme).opacity(Self.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    /// Chip label: the decoded title hard-truncated to ~30 characters (the
    /// FE truncates via CSS max-width; a character cap is the SwiftUI-simple
    /// equivalent).
    static func displayTitle(_ title: String) -> String {
        title.count > Constants.Conversation.ContextMention.titleMaximumLength
            ? String(title.prefix(Constants.Conversation.ContextMention.titleMaximumLength)) + "…"
            : title
    }

    /// SF Symbol per provider, mirroring the FE's provider→icon mapping
    /// (github → pull-request-ish, linear → ticket, sentry → bug,
    /// browser/external/unknown → link).
    static func iconName(for provider: String) -> String {
        switch provider {
        case "github": return "arrow.triangle.pull"
        case "linear": return "ticket"
        case "sentry": return "ladybug"
        default: return "link"
        }
    }
}

/// Minimal leading-aligned wrapping layout for a run of chips: places
/// subviews left-to-right at their ideal size and wraps to a new line when
/// the proposed width is exceeded.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
