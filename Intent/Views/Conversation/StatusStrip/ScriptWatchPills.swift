import SwiftUI

/// Script watch pills for the workspace status row. One watch opens its details
/// sheet directly; several collapse into a counted menu that opens the same sheet.
struct ScriptWatchPills: View {
    let viewModel: ConversationViewModel

    var body: some View {
        ScriptMonitorClock { now in
            HStack(spacing: Constants.Conversation.Design.Status.composerSpacing) {
                watches(now: now)
                if hasError || (isStale && !isLoading) { retryPill }
                if hasMore { loadMorePill }
            }
        }
        // No movement or countdown animation, including under Reduce Motion.
        .transaction { $0.animation = nil }
        .background {
            #if DEBUG
            if DemoMode.isEnabled, ProcessInfo.processInfo.arguments.contains("--demo-script-monitor-hit-probe") {
                DemoIPadPaneGeometry(identifier: "script-monitors")
            }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("script-monitors-status")
    }

    private var store: WorkspaceScriptMonitorsStore { viewModel.scriptMonitorsStore }
    private var isLoading: Bool { store.isLoading(for: viewModel.workspaceId) }
    private var isStale: Bool { store.isStale(for: viewModel.workspaceId) }
    private var hasError: Bool { store.error(for: viewModel.workspaceId) != nil }
    private var hasMore: Bool { store.nextCursor(for: viewModel.workspaceId) != nil }

    @ViewBuilder
    private func watches(now: Date) -> some View {
        let monitors = viewModel.activeAgentScriptMonitors
        if monitors.count == 1, let monitor = monitors.first {
            Button {
                viewModel.selectScriptMonitor(monitor)
            } label: {
                WorkspaceStatusPill(icon: .eye, text: Text("Watching \(monitor.scriptName)"), truncates: true)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Watching script \(monitor.scriptName)")
            .accessibilityValue(ScriptMonitorPresentation.expiry(monitor.expiresAt, now: now))
            .accessibilityHint("Opens read-only watch details")
            .accessibilityIdentifier("script-monitor-\(monitor.id)")
        } else if monitors.count > 1 {
            Menu {
                ForEach(monitors) { monitor in
                    Button {
                        viewModel.selectScriptMonitor(monitor)
                    } label: {
                        Text(verbatim: monitor.scriptName)
                        Text(ScriptMonitorPresentation.expiry(monitor.expiresAt, now: now))
                    }
                    .accessibilityIdentifier("script-monitor-\(monitor.id)")
                }
            } label: {
                WorkspaceStatusPill(icon: .eye, text: Text("Watching \(monitors.count) scripts"))
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityIdentifier("script-monitors-menu")
        } else if isLoading {
            WorkspaceStatusPill(icon: .eye, text: Text("Loading script watches…"))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("script-monitors-loading")
        }
    }

    private var retryPill: some View {
        Button {
            Task { await viewModel.retryScriptMonitors() }
        } label: {
            WorkspaceStatusPill(
                icon: .attentionCircle,
                text: Text(hasError ? "Script watches unavailable · Retry" : "Script watches may be out of date · Retry")
            )
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(isLoading)
        .accessibilityLabel("Script watches may be out of date. Retry")
        .accessibilityIdentifier("script-monitors-retry")
    }

    private var loadMorePill: some View {
        Button {
            Task { await store.loadMore(workspaceId: viewModel.workspaceId) }
        } label: {
            WorkspaceStatusPill(icon: .eye, text: Text("Load more script watches"))
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(isLoading)
        .accessibilityIdentifier("script-monitors-load-more")
    }
}
