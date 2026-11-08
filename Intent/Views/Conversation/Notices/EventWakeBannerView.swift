import SwiftUI

struct EventWakeBannerView: View {
    let attribution: EventWakeAttribution
    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Conversation.DividerNotice.labelSpacing) {
            Image(.notification)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(attribution.summaryLabel)
                .interFont(Constants.Typography.subtextXXS)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent woken by events: \(attribution.summaryLabel)")
        .accessibilityValue("\(attribution.eventCount) events")
    }
}
