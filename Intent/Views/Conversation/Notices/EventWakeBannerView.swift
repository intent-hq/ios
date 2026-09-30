import SwiftUI

/// Compact divider banner for event-subscription wake rows
/// (`metadata.type == "event_notification"`): bell icon + event summary,
/// with an event count when the summary lists individual activity. Replaces
/// the raw machine-text user bubble — the iOS counterpart of cloudlands-fe's
/// `EventWakeupBanner` (compact divider form; the expandable detail view is
/// FE-only polish).
struct EventWakeBannerView: View {
    let attribution: EventWakeAttribution
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: Constants.Conversation.DividerNotice.outerSpacing) {
            line
            HStack(spacing: Constants.Conversation.DividerNotice.labelSpacing) {
                Image(systemName: "bell.fill")
                    .font(.caption2)
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
        .accessibilityLabel("Agent woken by events: \(label)")
    }

    /// Summary plus a count suffix when several events collapsed into a
    /// per-event summary (count-only summaries already carry the number).
    private var label: String {
        let summary = attribution.summaryLabel
        if Constants.Conversation.EventWake.countLabelRange.contains(attribution.eventCount) {
            return "\(summary) · \(attribution.eventCount) events"
        }
        return summary
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: Constants.Conversation.DividerNotice.lineHeight)
            .frame(maxWidth: .infinity)
    }
}
