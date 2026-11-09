import SwiftUI

/// Compact attribution header for centralized PR-monitor wake messages
/// (`metadata.type == "pr_monitor_wake"`, PROTOCOL §5.42): pull-request icon
/// + tappable PR chip + "woke the agent". Mirrors HookWakeAttributionView,
/// but the chip opens the PR in the browser (metadata `url` first, GitHub
/// fallback; gated by the `ExternalLink` http/https allowlist) — the iOS
/// counterpart of cloudlands-fe's `PrMonitorWakeAttributionHeader`.
struct PrMonitorWakeAttributionView: View {
    private typealias Design = Constants.Conversation.Design

    let attribution: PrMonitorWakeAttribution
    /// `<owner>/<repo>` of the conversation's workspace, or nil when unknown
    /// (the chip label then falls back to the bare `#<n>` form).
    let workspaceRepo: String?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        WakeCardHeaderRow(icon: .gitPr) {
            VStack(alignment: .leading, spacing: Design.Watcher.attributionSpacing) {
                prLink
                Text("woke the agent")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .tracking(Design.Typography.smallTracking)
        }
    }

    private var prLink: some View {
        Button {
            if let url = ExternalLink.url(from: attribution.resolvedUrl) {
                openURL(url)
            }
        } label: {
            Text(attribution.chipLabel(workspaceRepo: workspaceRepo))
                .interFont(Constants.Typography.bodyXSEmphasized)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .underline()
                .fixedSize(horizontal: false, vertical: true)
                .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
    }
}
