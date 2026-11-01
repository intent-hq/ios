import SwiftUI

/// Centered inline divider chip for daemon-persisted model-change transcript
/// rows (metadata `{ type: "model_changed", from, to, fromProvider,
/// toProvider }`). Informational styling, visually distinct from both chat
/// bubbles and the amber warning banner — the row was never sent to the
/// provider (FE parity: ModelChangeNotice.svelte).
struct ModelChangeNoticeView: View {
    let notice: ModelChangeNotice
    /// Fallback text (the row's text content) when the metadata fields are
    /// absent.
    let fallbackText: String
    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 11

    private var label: String {
        notice.label(fallbackText: fallbackText)
    }

    var body: some View {
        HStack(spacing: Constants.Conversation.DividerNotice.outerSpacing) {
            line
            HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.DividerNotice.labelSpacing) {
                Image(.transfer)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
                Text(label)
                    .interFont(Constants.Typography.subtextXXS)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .layoutPriority(1)
            line
        }
        .padding(.vertical, Constants.Conversation.DividerNotice.verticalPadding)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: Constants.Conversation.DividerNotice.lineHeight)
            .frame(minWidth: Constants.Conversation.DividerNotice.minimumLineWidth, maxWidth: .infinity)
    }
}
