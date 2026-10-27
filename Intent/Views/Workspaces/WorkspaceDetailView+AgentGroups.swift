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

    var agentListRows: [WorkspaceAgentListRow] {
        var rows = agentTreeRows(viewModel.foregroundAgents)
        rows.append(contentsOf: agentSectionRows(.background, title: "background agents"))
        rows.append(contentsOf: agentSectionRows(.orphaned, title: "delegated agents"))
        rows.append(contentsOf: agentSectionRows(.retired, title: "retired agents"))
        return rows
    }

    private func agentTreeRows(_ roots: [AgentSession]) -> [WorkspaceAgentListRow] {
        // Snapshot values on-main; defer row bodies until the lazy stack requests them.
        viewModel.visibleTree(roots).map { row in
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
            return WorkspaceAgentListRow(id: "workspace.agent.\(row.id)", content: .agent(content))
        }
    }

    private func agentSectionRows(_ group: AgentListGroup, title: String) -> [WorkspaceAgentListRow] {
        let count = viewModel.count(for: group)
        let expanded = viewModel.isExpanded(group)
        guard count > 0 || expanded else { return [] }
        let header = BackgroundAgentsHeader(
            agents: viewModel.rows(for: group),
            totalCount: count,
            title: title,
            runningCount: viewModel.runningCount(for: group),
            isExpanded: expanded,
            colorScheme: colorScheme
        ) { Task { await toggleAgentGroup(group) } }
        var rows = [WorkspaceAgentListRow(id: group.accessibilityIdentifier, content: .header(header))]
        guard expanded else { return rows }

        let status = agentGroupLoadStatus(group)
        switch status {
        case .ready: break
        default:
            let content = WorkspaceAgentGroupStatus(status: status, identifier: group.accessibilityIdentifier) {
                Task { await agentStore.loadAgentGroup(group, workspaceId: workspaceId) }
            }
            rows.append(WorkspaceAgentListRow(id: group.accessibilityIdentifier + ".status", content: .status(content)))
        }
        if group == .retired {
            rows.append(contentsOf: viewModel.rows(for: group).map { agent in
                WorkspaceAgentListRow(id: "workspace.agent.\(agent.id)", content: .retired(agentButton(agent)))
            })
        } else {
            rows.append(contentsOf: agentTreeRows(viewModel.rows(for: group)))
        }
        return rows
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

    /// The conversation open beside this sidebar workspace.
    private var sidebarAgentId: String? {
        guard sidebar != nil, case let .agentConversation(agentId, _, _) = coordinator.currentScreen else { return nil }
        return agentId
    }

    func agentButton(_ agent: AgentSession, indented: Bool = false) -> WorkspaceAgentButton {
        WorkspaceAgentButton(
            agent: agent,
            colorScheme: colorScheme,
            indented: indented,
            isSelected: sidebarAgentId == agent.id,
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
