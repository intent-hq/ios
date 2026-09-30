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
        ForEach(viewModel.visibleTree(roots)) { row in
            VStack(spacing: WorkspaceDetailStyle.stackTopSpacing) {
                agentButton(row.agent, indented: row.depth > 0)
                let group = AgentListGroup.delegated(parentId: row.id)
                if viewModel.count(for: group) > 0 || viewModel.isExpanded(group) {
                    DelegatedAgentsRow(
                        agents: viewModel.rows(for: group),
                        totalCount: viewModel.count(for: group),
                        runningCount: viewModel.runningCount(for: group),
                        isExpanded: viewModel.isExpanded(group),
                        colorScheme: colorScheme
                    ) { Task { await toggleAgentGroup(group) } }
                    .accessibilityIdentifier(group.accessibilityIdentifier)
                    if viewModel.isExpanded(group) { agentGroupStatus(group) }
                }
            }
            .padding(.leading, CGFloat(max(0, row.depth - 1)) * WorkspaceDetailStyle.avatarSpacing)
        }
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
                    ForEach(viewModel.rows(for: group)) { agent in agentButton(agent) }
                } else {
                    agentTree(viewModel.rows(for: group))
                }
            }
        }
    }

    @ViewBuilder
    private func agentGroupStatus(_ group: AgentListGroup) -> some View {
        if agentStore.list.loadingGroups.contains(group) {
            ProgressView("Loading agents…")
                .font(.caption)
                .accessibilityIdentifier(group.accessibilityIdentifier + ".loading")
        } else if let error = agentStore.list.errors[group] {
            VStack {
                Text(error).interFont(Constants.Typography.subtextXXS)
                Button("Retry") {
                    Task { await agentStore.loadAgentGroup(group, workspaceId: workspaceId) }
                }
                .accessibilityIdentifier(group.accessibilityIdentifier + ".retry")
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        } else if agentStore.isAgentGroupLoaded(group), viewModel.rows(for: group).isEmpty {
            Text("No agents in this group")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }

    func agentButton(_ agent: AgentSession, indented: Bool = false) -> some View {
        Button {
            coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
        } label: {
            AgentRowView(agent: agent, colorScheme: colorScheme, indented: indented)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.agent.\(agent.id)")
        .visionListRowHitTarget()
        .contextMenu {
            AgentNotificationsMuteButton(agent: agent) { toggleNotificationsMuted(agent) }
        }
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
