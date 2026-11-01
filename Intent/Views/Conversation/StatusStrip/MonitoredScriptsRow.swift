import SwiftUI

/// The sheet host outlives an empty status row so a terminal event can explain
/// that the selected watch ended without asserting what happened to its run.
/// The workspace design shows its watches as pills in `WorkspaceStatusPillsRow`
/// and keeps only this host.
struct MonitoredScriptsRow: View {
    let viewModel: ConversationViewModel
    var showsRow = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var headingIconSize: CGFloat = 14

    private enum Layout {
        static let chipMaximumWidth: CGFloat = 280
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsRow, viewModel.showsScriptMonitorStatus {
                ScriptMonitorClock { now in
                    statusRow(now: now)
                }
                Divider()
            }
        }
        // No movement or countdown animation, including under Reduce Motion.
        .transaction { $0.animation = nil }
        .sheet(item: Binding(
            get: { viewModel.selectedScriptMonitor },
            set: { if $0 == nil { viewModel.closeScriptMonitor() } }
        )) { selection in
            ScriptMonitorDetailView(viewModel: viewModel, selection: selection)
                .coversConversationComposers()
        }
    }

    private var isLoading: Bool { viewModel.scriptMonitorsStore.isLoading(for: viewModel.workspaceId) }
    private var hasError: Bool { viewModel.scriptMonitorsStore.error(for: viewModel.workspaceId) != nil }
    private var hasMore: Bool { viewModel.scriptMonitorsStore.nextCursor(for: viewModel.workspaceId) != nil }

    private func statusRow(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Constants.Conversation.StatusStrip.contentSpacing) {
            if dynamicTypeSize.isAccessibilitySize { heading }
            ScrollView(.horizontal) {
                HStack(spacing: Constants.Conversation.StatusStrip.contentSpacing) {
                    if !dynamicTypeSize.isAccessibilitySize { heading }
                    if isLoading {
                        Text("Loading script watches…")
                            .font(.caption)
                            .accessibilityIdentifier("script-monitors-loading")
                    }
                    if hasError {
                        retryButton
                    } else if viewModel.scriptMonitorsStore.isStale(for: viewModel.workspaceId), !isLoading {
                        Text("Script watches may be out of date")
                            .font(.caption)
                        retryButton
                    }
                    ForEach(viewModel.activeAgentScriptMonitors) { monitor in
                        watchButton(monitor, now: now)
                    }
                    if hasMore { loadMoreButton }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Constants.Conversation.StatusStrip.horizontalPadding)
        .padding(.vertical, Constants.Conversation.StatusStrip.verticalPadding)
        .background {
            #if DEBUG
            if DemoMode.isEnabled, ProcessInfo.processInfo.arguments.contains("--demo-script-monitor-hit-probe") {
                DemoIPadPaneGeometry(identifier: "script-monitors")
            }
            #endif
        }
        .foregroundStyle(Theme.foreground(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("script-monitors-status")
    }

    private var heading: some View {
        Label {
            Text("Watching scripts")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(.eye)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: headingIconSize, height: headingIconSize)
        }
            .font(.caption)
            .accessibilityAddTraits(.isHeader)
    }

    private var loadMoreButton: some View {
        Button {
            Task { await viewModel.scriptMonitorsStore.loadMore(workspaceId: viewModel.workspaceId) }
        } label: {
            Text("Load more script watches")
                .font(.caption)
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(isLoading)
        .accessibilityIdentifier("script-monitors-load-more")
    }

    private var retryButton: some View {
        Button {
            Task { await viewModel.retryScriptMonitors() }
        } label: {
            Label {
                Text("Script watches unavailable · Retry")
            } icon: {
                Image(.attentionCircle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: headingIconSize, height: headingIconSize)
            }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(isLoading)
        .accessibilityLabel("Script watches may be out of date. Retry")
        .accessibilityIdentifier("script-monitors-retry")
    }

    private func watchButton(_ monitor: ScriptMonitorSummary, now: Date) -> some View {
        Button {
            viewModel.selectScriptMonitor(monitor)
        } label: {
            VStack(alignment: .leading) {
                Text(verbatim: monitor.scriptName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(ScriptMonitorPresentation.expiry(monitor.expiresAt, now: now))
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Layout.chipMaximumWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Constants.Conversation.StatusStrip.chipHorizontalPadding)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget, alignment: .leading)
            .background(Theme.muted(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.StatusStrip.chipCornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Watching script \(monitor.scriptName)")
        .accessibilityValue(ScriptMonitorPresentation.expiry(monitor.expiresAt, now: now))
        .accessibilityHint("Opens read-only watch details")
        .accessibilityIdentifier("script-monitor-\(monitor.id)")
    }
}
