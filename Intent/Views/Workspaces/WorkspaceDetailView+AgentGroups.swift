import SwiftUI

extension WorkspaceDetailView {
    func resetAgentWorkspace(to workspaceId: String) {
        viewModel.reset()
        agentStore.prepareForWorkspaceChange(to: workspaceId)
    }

    func toggleAgentGroup(_ group: AgentListGroup) async {
        viewModel.toggle(group)
        if viewModel.isExpanded(group) {
            await agentStore.loadAgentGroup(group, workspaceId: workspaceId)
        }
    }

    func agentTree(_ roots: [AgentSession]) -> some View {
        // Snapshot values on-main; defer row bodies until the lazy stack requests them.
        let rows = viewModel.visibleTree(roots).map { row in
            let group = AgentListGroup.delegated(parentId: row.id)
            let count = viewModel.count(for: group)
            let expanded = viewModel.isExpanded(group)
            let content = WorkspaceAgentTreeRow(
                button: agentButton(row.agent, indented: row.depth > 0),
                depth: row.depth,
                group: count > 0 || expanded ? WorkspaceAgentGroupSnapshot(
                    agents: Array(viewModel.rows(for: group).prefix(Constants.AgentRow.maximumHeaderAvatars)),
                    totalCount: count,
                    runningCount: viewModel.runningCount(for: group),
                    isExpanded: expanded,
                    identifier: group.accessibilityIdentifier,
                    status: agentGroupLoadStatus(group)
                ) : nil,
                colorScheme: colorScheme,
                onLoadGroup: { await agentStore.loadAgentGroup(group, workspaceId: workspaceId) },
                onToggle: { Task { await toggleAgentGroup(group) } },
                onRetry: { Task { await agentStore.loadAgentGroup(group, workspaceId: workspaceId) } }
            )
            return (id: row.id, content: content)
        }
        return ForEach(rows, id: \.id) { @Sendable row in row.content }
    }

    @ViewBuilder
    func agentSection(_ group: AgentListGroup, title: String) -> some View {
        if viewModel.count(for: group) > 0 || viewModel.isExpanded(group) {
            BackgroundAgentsHeader(
                agents: viewModel.rows(for: group),
                totalCount: viewModel.count(for: group),
                title: title,
                runningCount: viewModel.runningCount(for: group),
                isExpanded: viewModel.isExpanded(group),
                colorScheme: colorScheme
            ) { Task { await toggleAgentGroup(group) } }
            .accessibilityIdentifier(group.accessibilityIdentifier)
            if viewModel.isExpanded(group) {
                agentGroupStatus(group)
                if group == .retired {
                    let rows = viewModel.rows(for: group).map { agent in
                        (id: agent.id, content: agentButton(agent))
                    }
                    ForEach(rows, id: \.id) { @Sendable row in row.content }
                } else {
                    agentTree(viewModel.rows(for: group))
                }
            }
        }
    }

    @ViewBuilder
    private func agentGroupStatus(_ group: AgentListGroup) -> some View {
        WorkspaceAgentGroupStatus(status: agentGroupLoadStatus(group), identifier: group.accessibilityIdentifier) {
            Task { await agentStore.loadAgentGroup(group, workspaceId: workspaceId) }
        }
    }

    private func agentGroupLoadStatus(_ group: AgentListGroup) -> WorkspaceAgentGroupSnapshot.LoadStatus {
        if agentStore.list.loadingGroups.contains(group) {
            return .loading
        }
        if let error = agentStore.list.errors[group] {
            return .failed(error)
        }
        if agentStore.isAgentGroupLoaded(group), viewModel.rows(for: group).isEmpty {
            return .empty
        }
        return .ready
    }

    func agentButton(_ agent: AgentSession, indented: Bool = false) -> WorkspaceAgentButton {
        WorkspaceAgentButton(
            agent: agent,
            colorScheme: colorScheme,
            indented: indented,
            onSelect: { coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name) },
            onMute: { toggleNotificationsMuted(agent) }
        )
    }

    private func toggleNotificationsMuted(_ agent: AgentSession) {
        Task {
            do {
                try await agentStore.setNotificationsMuted(
                    agentId: agent.id, workspaceId: workspaceId, muted: !agent.notificationsMuted
                )
            } catch {
                AppLog.workspace.error("[WorkspaceDetail] Notification mute toggle failed: \(error)")
            }
        }
    }
}

extension AgentListGroup {
    var accessibilityIdentifier: String {
        switch self {
        case .background: "workspace.agents.background"
        case let .delegated(parentId): "workspace.agents.children.\(parentId)"
        case .orphaned: "workspace.agents.delegated"
        case .retired: "workspace.agents.retired"
        }
    }
}
