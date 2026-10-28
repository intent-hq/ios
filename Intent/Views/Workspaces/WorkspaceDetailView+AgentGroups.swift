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
            onSelect: {
                if sidebar == nil {
                    coordinator.workspaceSidebarAgents.handoff = .init(workspaceId: workspaceId, expansion: viewModel.expansion)
                }
                coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
            },
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

// MARK: - Sidebar selection

extension WorkspaceDetailView {
    private static let revealPasses = 4

    /// The sidebar copy keeps the open agent's row in view, and reports whether it lists it.
    var sidebarContent: some View {
        presentedContent
            .onAppear(perform: adoptOverviewExpansion)
            .onChange(of: sidebarAgentId, initial: true) { _, agentId in
                // An agent opened from elsewhere is found on the Agents tab.
                if agentId != nil, currentTab != .agents { currentTab = .agents }
            }
            .task(id: sidebarRevealKey) { await revealSidebarAgent() }
            .onChange(of: sidebarListing, initial: true) { _, listing in
                coordinator.workspaceSidebarAgents.listing = listing
            }
            .onDisappear {
                if coordinator.workspaceSidebarAgents.listing?.owner == ObjectIdentifier(viewModel) {
                    coordinator.workspaceSidebarAgents.listing = nil
                }
            }
    }

    /// The overview's open sections carry over, so the agent just opened from one stays visible.
    private func adoptOverviewExpansion() {
        guard let handoff = coordinator.workspaceSidebarAgents.handoff, handoff.workspaceId == workspaceId else { return }
        viewModel.expansion = handoff.expansion
        coordinator.workspaceSidebarAgents.handoff = nil
    }

    private func sidebarAgent(_ agentId: String) -> AgentSession? {
        agentStore.agents.first { $0.id == agentId }
            ?? coordinator.agentDetails.cached(agentId: agentId).flatMap { AgentSession.parseAgent($0.values) }
    }

    private var sidebarRevealGroups: Set<AgentListGroup> {
        guard let agent = sidebarAgentId.flatMap(sidebarAgent) else { return [] }
        return WorkspaceSidebarAgents.revealGroups(for: agent, lookup: sidebarAgent)
    }

    private var sidebarRevealKey: String? {
        guard let agentId = sidebarAgentId, agentStore.hasLoaded else { return nil }
        return "\(agentId)|\(sidebarAgent(agentId) != nil)"
    }

    private var pendingAgentGroups: Set<AgentListGroup> {
        viewModel.expandedGroups.union(sidebarRevealGroups).filter { group in
            !agentStore.isAgentGroupLoaded(group) && agentStore.list.errors[group] == nil
        }
    }

    /// Opens and loads the sections above the agent; each loaded parent may reveal its own section.
    private func revealSidebarAgent() async {
        for _ in 0 ..< Self.revealPasses {
            for group in sidebarRevealGroups where !viewModel.isExpanded(group) { viewModel.toggle(group) }
            let pending = pendingAgentGroups
            guard !pending.isEmpty, !Task.isCancelled else { return }
            for group in pending { await agentStore.loadAgentGroup(group, workspaceId: workspaceId) }
        }
    }

    private var sidebarListing: WorkspaceSidebarAgents.Listing? {
        guard let agentId = sidebarAgentId, currentTab == .agents else { return nil }
        let isListed = agentListRows.contains { $0.id == "workspace.agent.\(agentId)" }
        // While its sections load, expect the row rather than flash the conversation's title.
        let isSettling = !agentStore.hasLoaded || !pendingAgentGroups.isEmpty
        guard isListed || isSettling else { return nil }
        return .init(workspaceId: workspaceId, agentId: agentId, owner: ObjectIdentifier(viewModel))
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
