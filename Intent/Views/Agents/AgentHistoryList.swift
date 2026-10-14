import SwiftUI

/// The right-edge drawer's panel: visited agents across every saved device.
/// Reads the live stores here so their updates re-render only this panel.
struct AgentHistoryList: View {
    let onSelect: (AgentHistoryEntry) -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// Snapshot store values before SwiftUI builds rows on its async render thread.
    private struct HistoryRow: Identifiable, Equatable {
        let entry: AgentHistoryEntry
        let title: String
        let subtitle: String
        let timestamp: String
        let isCurrent: Bool
        var id: AgentHistoryEntry.ID { entry.id }
    }

    private var secondaryForeground: Color {
        Constants.Connections.sectionForeground(for: colorScheme, contrast: contrast)
    }

    var body: some View {
        let rows = rowSnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: ConnectionSwitcherStyle.headingSpacing) {
                header(hasEntries: !rows.isEmpty)

                if rows.isEmpty {
                    Text("Agents you open on any device appear here.")
                        .interFont(Constants.Typography.bodyS)
                } else {
                    rowList(rows)
                        .padding(.horizontal, -ConnectionSwitcherStyle.rowInset)
                }
            }
            .padding(.vertical, ConnectionSwitcherStyle.inset)
            .padding(.horizontal, ConnectionSwitcherStyle.rowInset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
        .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
        .padding(.leading, ConnectionSwitcherStyle.trailingInset - ConnectionSwitcherStyle.rowInset)
        .padding(.trailing, ConnectionSwitcherStyle.inset - ConnectionSwitcherStyle.rowInset)
        .accessibilityIdentifier("agent-history.list")
    }

    private var rowSnapshot: [HistoryRow] {
        coordinator.visibleAgentHistory.map { entry in
            let workspaceTitle = workspaceTitle(for: entry)
            return HistoryRow(
                entry: entry,
                title: workspaceTitle ?? entry.agentName,
                subtitle: subtitle(for: entry, showsAgentName: workspaceTitle != nil),
                timestamp: entry.visitedAt.relativeFormatted,
                isCurrent: coordinator.isShowingConversation(of: entry)
            )
        }
    }

    private func rowList(_ rows: [HistoryRow]) -> some View {
        // Resolve environment values and actions before SwiftUI's async row callback.
        let content = rows.map { (id: $0.id, content: rowView($0)) }
        return VStack(spacing: ConnectionSwitcherStyle.rowSpacing) {
            ForEach(content, id: \.id) { @Sendable row in row.content }
        }
    }

    private func header(hasEntries: Bool) -> some View {
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

            if hasEntries {
                Button("Clear") { coordinator.agentHistory.clear() }
                    .buttonStyle(IntentContentButtonStyle())
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(secondaryForeground)
                    .accessibilityLabel("Clear agent history")
                    .accessibilityIdentifier("agent-history.clear")
            }
        }
    }

    private func rowView(_ row: HistoryRow) -> some View {
        Button { onSelect(row.entry) } label: {
            HStack(spacing: ConnectionSwitcherStyle.rowInset) {
                VStack(alignment: .leading, spacing: ConnectionSwitcherStyle.rowTextSpacing) {
                    Text(row.title)
                        .interFont(Constants.Typography.bodySEmphasized)
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(secondaryForeground)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.timestamp)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(secondaryForeground)
            }
            .padding(ConnectionSwitcherStyle.rowInset)
            .frame(maxWidth: .infinity, minHeight: ConnectionSwitcherStyle.rowHeight, alignment: .leading)
            .background(
                row.isCurrent ? ConnectionSwitcherStyle.selection(for: colorScheme) : .clear,
                in: .rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius)
            )
            .contentShape(.rect(cornerRadius: ConnectionSwitcherStyle.cornerRadius))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier("agent-history.entry.\(row.id)")
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

    /// Device, then agent; the agent name moves to the title when the workspace is unknown.
    private func subtitle(for entry: AgentHistoryEntry, showsAgentName: Bool) -> String {
        let device = coordinator.savedConnections.first { $0.id == entry.connectionId }?.displayName
        return [device, showsAgentName ? entry.agentName : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
