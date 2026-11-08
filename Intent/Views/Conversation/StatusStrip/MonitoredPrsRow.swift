import SwiftUI

/// Faint chip row above the composer surfacing the active agent's monitored
/// PRs (PROTOCOL §5.42) — the iOS counterpart of cloudlands-fe's
/// `MonitoredPrsRow`, rendered ABOVE the background-hooks row when both
/// exist. One chip per `active` monitor: the label is `#<number>`, prefixed
/// `<owner/repo>: ` only when the monitor's repo differs from the workspace
/// repo, with an amber dot while changes are pending the debounce emit.
/// Tapping a chip opens a menu whose header shows the last-refresh detail
/// (title, repo#number, checks/approvals/threads summary, mergeable/blocked
/// status, last change time, pending status) with Check and flush / Open PR /
/// Cancel monitor actions. The parent hides the row entirely when the agent
/// has no active monitors.
struct MonitoredPrsRow: View {
    let viewModel: ConversationViewModel
    private let monitoredPrStore: MonitoredPrStore
    private let usesWorkspaceDesign: Bool
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 11

    private typealias Layout = Constants.Conversation.StatusStrip.MonitoredPrs

    init(viewModel: ConversationViewModel, monitoredPrStore: MonitoredPrStore, usesWorkspaceDesign: Bool = false) {
        self.viewModel = viewModel
        self.monitoredPrStore = monitoredPrStore
        self.usesWorkspaceDesign = usesWorkspaceDesign
    }

    private var activeMonitors: [MonitoredPr] {
        monitoredPrStore.activeMonitors.filter { $0.agentId == viewModel.agentId }
    }

    var body: some View {
        if usesWorkspaceDesign {
            VStack(alignment: .leading, spacing: Constants.Conversation.Design.Status.composerSpacing) {
                if monitoredPrStore.error != nil { retryButton }
                if activeMonitors.count == 1, let monitor = activeMonitors.first {
                    monitorChip(monitor)
                } else if activeMonitors.count == 2 {
                    WorkspaceStatusPillsLayout(spacing: Constants.Conversation.Design.Status.composerSpacing, layoutDirection: layoutDirection) {
                        ForEach(activeMonitors) { monitor in
                            monitorChip(monitor)
                        }
                    }
                } else if !activeMonitors.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: Constants.Conversation.Design.Status.composerSpacing) {
                            ForEach(activeMonitors) { monitor in
                                monitorChip(monitor)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        } else {
            legacyRow
        }
    }

    private var legacyRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Constants.Conversation.StatusStrip.contentSpacing) {
                Image(.gitPr)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
                Text("Monitored PRs")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                if monitoredPrStore.error != nil { retryButton }

                ForEach(monitoredPrStore.activeMonitors.filter { $0.agentId == viewModel.agentId }) { monitor in
                    monitorChip(monitor)
                }
            }
            .padding(.horizontal, Constants.Conversation.StatusStrip.horizontalPadding)
            .padding(.vertical, Constants.Conversation.StatusStrip.verticalPadding)
        }
        .scrollIndicators(.hidden)
        .background(Theme.card(for: colorScheme).opacity(viewModel.showsLoadingState ? 0 : Constants.Conversation.StatusStrip.backgroundOpacity))
        .opacity(Constants.Conversation.StatusStrip.contentOpacity)
    }

    private var retryButton: some View {
        Button {
            Task { await monitoredPrStore.refetch() }
        } label: {
            Label {
                Text("Status unavailable · Retry")
            } icon: {
                Image(.attentionCircle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .buttonStyle(IntentContentButtonStyle())
        .font(.caption2)
        .accessibilityLabel("PR monitors may be out of date. Retry refresh")
        .accessibilityIdentifier("monitoredPr.retry")
    }

    // MARK: - Chip

    @ViewBuilder
    private func monitorChip(_ monitor: MonitoredPr) -> some View {
        Menu {
            // Detail header: last-refresh summary (mirrors the FE hover card).
            // Positional IDs: lines are display strings with no inherent
            // identity, and \.self would collide if two lines ever matched.
            ForEach(Array(Self.detailLines(monitor).enumerated()), id: \.offset) { _, line in
                Text(line)
            }
            Divider()
            Button {
                Task {
                    await monitoredPrStore.flush(
                        monitorId: monitor.monitorId,
                        mode: .refreshFirst
                    )
                }
            } label: {
                Label("Check and flush", image: "ClockwiseArrow")
            }
            .disabledWhileReadOnly()
            Button {
                if let url = ExternalLink.url(from: Self.prUrl(monitor)) {
                    openURL(url)
                }
            } label: {
                Label("Open PR", image: "External")
            }
            Button(role: .destructive) {
                Task { await monitoredPrStore.cancel(monitorId: monitor.monitorId) }
            } label: {
                Label("Cancel monitor", image: "Close")
            }
            .disabledWhileReadOnly()
        } label: {
            if usesWorkspaceDesign {
                workspacePill(monitor)
            } else {
                chipLabel(monitor)
            }
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("monitoredPr.\(monitor.monitorId)")
        .accessibilityLabel(
            usesWorkspaceDesign
                ? Text("Monitoring PR \(Self.chipLabel(monitor, workspaceRepo: workspaceRepo))")
                : Text(Self.chipLabel(monitor, workspaceRepo: workspaceRepo))
        )
        .accessibilityValue(Text(Self.pendingSummary(monitor)))
    }

    private func workspacePill(_ monitor: MonitoredPr) -> some View {
        WorkspaceStatusPill(
            icon: .infoCircle,
            text: Text("Monitoring PR \(Self.chipLabel(monitor, workspaceRepo: workspaceRepo))")
        ) {
            if monitor.hasPendingChanges {
                Circle()
                    .fill(Color.orange)
                    .frame(width: Layout.pendingIndicatorSide, height: Layout.pendingIndicatorSide)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func chipLabel(_ monitor: MonitoredPr) -> some View {
        HStack(spacing: Constants.Conversation.StatusStrip.chipSpacing) {
            Text(Self.chipLabel(monitor, workspaceRepo: workspaceRepo))
                .interFont(Constants.Typography.subtextXXS)
                .lineLimit(1)
            if monitor.hasPendingChanges {
                Circle()
                    .fill(Color.orange.opacity(Layout.pendingIndicatorOpacity))
                    .frame(width: Layout.pendingIndicatorSide, height: Layout.pendingIndicatorSide)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .padding(.horizontal, Constants.Conversation.StatusStrip.chipHorizontalPadding)
        .padding(.vertical, Layout.chipVerticalPadding)
        .background(Theme.muted(for: colorScheme).opacity(Layout.chipBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.StatusStrip.chipCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Conversation.StatusStrip.chipCornerRadius)
                .strokeBorder(
                    Theme.border(for: colorScheme).opacity(Constants.Conversation.StatusStrip.chipBorderOpacity),
                    lineWidth: Constants.Conversation.StatusStrip.chipBorderWidth
                )
        )
    }

    private var workspaceRepo: String? {
        guard let workspace = session.workspaceStore.workspaces.first(
                where: { $0.id == viewModel.workspaceId }
        ),
              let owner = workspace.repositoryOwner,
              let name = workspace.repositoryName else { return nil }
        return "\(owner)/\(name)"
    }

    // MARK: - Display helpers (pure, unit-tested)

    /// Chip label: `#42`, prefixed `owner/repo: ` only for cross-repo PRs.
    /// Falls back to the bare number when the workspace repo is unknown.
    static func chipLabel(_ monitor: MonitoredPr, workspaceRepo: String?) -> String {
        let number = "#\(monitor.prNumber)"
        if let workspaceRepo, monitor.repo != workspaceRepo {
            return "\(monitor.repo): \(number)"
        }
        return number
    }

    /// PR web URL: the wire `url` when present, else the canonical GitHub form.
    /// The Open PR action only opens it once it passes the `ExternalLink`
    /// http/https allowlist.
    static func prUrl(_ monitor: MonitoredPr) -> String {
        monitor.url ?? "https://github.com/\(monitor.repo)/pull/\(monitor.prNumber)"
    }

    /// Menu-header detail lines: title (+ state), repo#number with
    /// checks/approvals/threads summary, mergeable/blocked status, "last
    /// change … ago" (relative to `now` when the menu renders), and pending
    /// status. The summary line is dropped when it would duplicate the title
    /// line (the no-title/no-snapshot fallback), so every line is distinct.
    static func detailLines(_ monitor: MonitoredPr, now: Date = Date()) -> [String] {
        var lines: [String] = []
        var titleLine = monitor.title ?? "\(monitor.repo)#\(monitor.prNumber)"
        if let state = monitor.lastSnapshot?.state {
            titleLine += " — \(state)"
        }
        lines.append(titleLine)

        var summary = ["\(monitor.repo)#\(monitor.prNumber)"]
        if let checks = checksSummary(monitor) { summary.append(checks) }
        if let approvals = approvalsSummary(monitor) { summary.append(approvals) }
        if let threads = threadsSummary(monitor) { summary.append(threads) }
        let summaryLine = summary.joined(separator: " · ")
        if summaryLine != titleLine {
            lines.append(summaryLine)
        }

        if let merge = mergeSummary(monitor) { lines.append(merge) }
        if let lastChange = ISO8601DateFormatter.lenientDate(from: monitor.lastChangeAt) {
            lines.append("Last change \(DurationFormat.compact(now.timeIntervalSince(lastChange))) ago")
        }

        lines.append(pendingSummary(monitor))
        return lines
    }

    /// Mergeable / blocked line; prefers the explicit blocked reason (nil
    /// while the forge is still computing mergeability).
    static func mergeSummary(_ monitor: MonitoredPr) -> String? {
        guard let snapshot = monitor.lastSnapshot else { return nil }
        if let reason = snapshot.mergeBlockedReason, !reason.isEmpty {
            return "Merge blocked: \(reason)"
        }
        switch snapshot.mergeability {
        case .computing:
            return nil
        case .mergeable:
            return "Mergeable"
        case .notMergeable:
            return "Not mergeable"
        }
    }

    /// Compact checks summary from the last snapshot, e.g. "3/4 passing".
    static func checksSummary(_ monitor: MonitoredPr) -> String? {
        guard let checks = monitor.lastSnapshot?.checks, checks.total > 0 else { return nil }
        if checks.failed > 0 { return "\(checks.failed)/\(checks.total) failing" }
        if checks.pending > 0 { return "\(checks.pending)/\(checks.total) pending" }
        return "\(checks.passed)/\(checks.total) passing"
    }

    /// Compact approvals summary, e.g. "approved (1/2 approvals)".
    static func approvalsSummary(_ monitor: MonitoredPr) -> String? {
        guard let approvals = monitor.lastSnapshot?.approvals else { return nil }
        if let needed = approvals.needed {
            let noun = needed == 1 ? "approval" : "approvals"
            return "\(approvals.decision) (\(approvals.have)/\(needed) \(noun))"
        }
        let noun = approvals.have == 1 ? "approval" : "approvals"
        return "\(approvals.decision) (\(approvals.have) \(noun))"
    }

    /// Unresolved-threads summary; nil when there are none.
    static func threadsSummary(_ monitor: MonitoredPr) -> String? {
        guard let threads = monitor.lastSnapshot?.threads, threads.unresolved > 0 else { return nil }
        return threads.unresolved == 1
            ? "1 unresolved thread"
            : "\(threads.unresolved) unresolved threads"
    }

    /// Pending-emit status line for the detail header.
    static func pendingSummary(_ monitor: MonitoredPr) -> String {
        guard monitor.hasPendingChanges else { return "No pending changes" }
        guard !monitor.pendingChanges.isEmpty else { return "Pending changes" }
        return monitor.pendingChanges.count == 1
            ? "1 pending change"
            : "\(monitor.pendingChanges.count) pending changes"
    }
}
