import Foundation

extension AppCoordinator {
    /// Records every route into a conversation (taps, restore, alerts, history).
    func recordAgentVisit() {
        guard case let .agentConversation(agentId, workspaceId, agentName) = currentScreen,
              let connectionID = windowConnectionID else { return }
        agentHistory.record(AgentHistoryEntry(
            connectionId: connectionID,
            workspaceId: workspaceId,
            workspaceTitle: dependencies.workspaceStore.workspaces.first { $0.id == workspaceId }?.title,
            agentId: agentId,
            agentName: agentName,
            visitedAt: .now
        ))
    }

    /// History entries this window can offer: the device must still be saved.
    var visibleAgentHistory: [AgentHistoryEntry] {
        AgentHistory.visible(agentHistory.entries, savedConnectionIDs: Set(savedConnections.map(\.id)))
    }

    func isShowingConversation(of entry: AgentHistoryEntry) -> Bool {
        guard case let .agentConversation(agentId, _, _) = currentScreen else { return false }
        return agentId == entry.agentId && windowConnectionID == entry.connectionId
    }

    /// Opens a history entry, switching device when the agent lives on another backend.
    func onSelectHistoryEntry(_ entry: AgentHistoryEntry, notifications: NotificationManager = .shared) {
        guard !isShowingConversation(of: entry) else { return }
        if entry.connectionId == windowConnectionID {
            onSelectAgent(entry.agentId, workspaceId: entry.workspaceId, agentName: entry.agentName)
            return
        }
        notifications.routeHistorySelection(
            agentId: entry.agentId,
            workspaceId: entry.workspaceId,
            agentName: entry.agentName,
            connectionId: entry.connectionId
        ) { onSwitchConnection(id: $0) }
    }
}
