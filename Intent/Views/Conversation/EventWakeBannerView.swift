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
        HStack(spacing: 12) {
            line
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                Text(label)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .layoutPriority(1)
            line
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent woken by events: \(label)")
    }

    /// Summary plus a count suffix when several events collapsed into a
    /// per-event summary (count-only summaries already carry the number).
    private var label: String {
        let summary = attribution.summaryLabel
        if attribution.eventCount > 1, attribution.eventCount < 5 {
            return "\(summary) · \(attribution.eventCount) events"
        }
        return summary
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
