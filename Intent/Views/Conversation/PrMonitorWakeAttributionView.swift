import SwiftUI

/// Compact attribution header for centralized PR-monitor wake messages
/// (`metadata.type == "pr_monitor_wake"`, PROTOCOL §5.42): pull-request icon
/// + tappable PR chip + "woke the agent". Mirrors HookWakeAttributionView,
/// but the chip opens the PR in the browser (metadata `url` first, GitHub
/// fallback) — the iOS counterpart of cloudlands-fe's
/// `PrMonitorWakeAttributionHeader`.
struct PrMonitorWakeAttributionView: View {
    let attribution: PrMonitorWakeAttribution
    /// `<owner>/<repo>` of the conversation's workspace, or nil when unknown
    /// (the chip label then falls back to the bare `#<n>` form).
    let workspaceRepo: String?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.triangle.pull")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Button {
                if let url = URL(string: attribution.resolvedUrl) {
                    openURL(url)
                }
            } label: {
                Text(attribution.chipLabel(workspaceRepo: workspaceRepo))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Text("woke the agent")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }
}
