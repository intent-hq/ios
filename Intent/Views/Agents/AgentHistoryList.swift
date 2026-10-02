import SwiftUI

/// The right-edge drawer's panel: visited agents across every saved device.
/// Reads the live stores here so their updates re-render only this panel.
struct AgentHistoryList: View {
    let onSelect: (AgentHistoryEntry) -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var avatarSize = ConnectionSwitcherStyle.iconSize
    /// Tallest rendered row; rows grow with Dynamic Type, so the cap is measured.
    @State private var rowHeight: CGFloat = 0

    private var entries: [AgentHistoryEntry] { coordinator.visibleAgentHistory }

    private var secondaryForeground: Color {
        Constants.Connections.sectionForeground(for: colorScheme, contrast: contrast)
    }

    /// Rows past the visible count scroll beneath the fixed header.
    private var rowsMaxHeight: CGFloat? {
        guard rowHeight > 0 else { return nil }
        let rows = CGFloat(ConnectionSwitcherStyle.historyVisibleRows)
        return rows * rowHeight + (rows - 1) * ConnectionSwitcherStyle.rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConnectionSwitcherStyle.headingSpacing) {
            header

            if entries.isEmpty {
                Text("Agents you open on any device appear here.")
                    .interFont(Constants.Typography.bodyS)
            } else {
                ScrollView {
                    VStack(spacing: ConnectionSwitcherStyle.rowSpacing) {
                        ForEach(entries) { entry in
                            row(entry)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                    rowHeight = max(rowHeight, height)
                                }
                        }
                    }
                }
                .frame(maxHeight: rowsMaxHeight)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.vertical, ConnectionSwitcherStyle.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onChange(of: dynamicTypeSize) { rowHeight = 0 }
        .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
        .padding(.leading, ConnectionSwitcherStyle.trailingInset)
        .padding(.trailing, ConnectionSwitcherStyle.inset)
        .accessibilityIdentifier("agent-history.list")
    }

    private var header: some View {
        HStack {
            ConnectionSheetText(
                "Recent agents",
                style: Constants.Typography.eyebrow,
                tracking: Constants.ManualTokenEntry.labelTracking
            )
            .textCase(.uppercase)
            .foregroundStyle(secondaryForeground)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if !entries.isEmpty {
                Button("Clear") { coordinator.agentHistory.clear() }
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(secondaryForeground)
                    .accessibilityLabel("Clear agent history")
                    .accessibilityIdentifier("agent-history.clear")
            }
        }
    }

    private func row(_ entry: AgentHistoryEntry) -> some View {
        let isCurrent = coordinator.isShowingConversation(of: entry)
        let workspaceTitle = workspaceTitle(for: entry)
        let subtitle = subtitle(for: entry, showsAgentName: workspaceTitle != nil)
        return Button { onSelect(entry) } label: {
            HStack(spacing: ConnectionSwitcherStyle.rowInset) {
                AgentAvatarView(agentId: entry.agentId, size: avatarSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ConnectionSwitcherStyle.rowTextSpacing) {
                    Text(workspaceTitle ?? entry.agentName)
                        .interFont(Constants.Typography.bodySEmphasized)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(secondaryForeground)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.visitedAt.relativeFormatted)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(secondaryForeground)
            }
            .padding(ConnectionSwitcherStyle.rowInset)
            .frame(maxWidth: .infinity, minHeight: ConnectionSwitcherStyle.rowHeight, alignment: .leading)
            .background(
                isCurrent ? ConnectionSwitcherStyle.selection(for: colorScheme) : .clear,
                in: .rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius)
            )
            .contentShape(.rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius))
        }
        .buttonStyle(ConnectionSheetButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("agent-history.entry.\(entry.id)")
    }

    /// The open device's workspace title is read live; others use the title from the visit.
    private func workspaceTitle(for entry: AgentHistoryEntry) -> String? {
        var liveTitle: String?
        if entry.connectionId == coordinator.windowConnectionID {
            liveTitle = session.workspaceStore.workspaces.first { $0.id == entry.workspaceId }?.title
        }
        guard let title = liveTitle ?? entry.workspaceTitle, !title.isEmpty else { return nil }
        return title
    }

    /// Agent and device; the agent name moves to the title when the workspace is unknown.
    private func subtitle(for entry: AgentHistoryEntry, showsAgentName: Bool) -> String {
        let device = coordinator.savedConnections.first { $0.id == entry.connectionId }?.displayName
        return [showsAgentName ? entry.agentName : nil, device]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
