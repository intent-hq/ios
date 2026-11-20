import Foundation

extension AppCoordinator {
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

    func forgetHistory(ofWorkspace workspaceId: String) {
        guard let connectionID = windowConnectionID, socketReachesWindowDevice else { return }
        agentHistory.removeWorkspace(workspaceId, on: connectionID)
    }

    private var socketReachesWindowDevice: Bool {
        let connection = dependencies.connection
        guard connection.connectionState == .connected,
              connection.pairingAttemptID == nil,
              let admission = connection.admission,
              let saved = windowConnection else { return false }
        return admission.token == saved.token && admission.fingerprint == saved.server.certFingerprint
    }

    var visibleAgentHistory: [AgentHistoryEntry] {
        AgentHistory.visible(agentHistory.entries, savedConnectionIDs: Set(savedConnections.map(\.id)))
    }

    func isShowingConversation(of entry: AgentHistoryEntry) -> Bool {
        guard case let .agentConversation(agentId, _, _) = currentScreen else { return false }
        return agentId == entry.agentId && windowConnectionID == entry.connectionId
    }

    func onSelectHistoryEntry(
        _ entry: AgentHistoryEntry,
        notifications: NotificationManager = .shared,
        opensSeparateBackendWindows: Bool = WindowRetargetRoute.platformOpensSeparateBackendWindows
    ) {
        guard !isShowingConversation(of: entry) else { return }
        if entry.connectionId == windowConnectionID {
            onSelectAgent(entry.agentId, workspaceId: entry.workspaceId, agentName: entry.agentName)
            return
        }
        notifications.routeHistorySelection(
            agentId: entry.agentId,
            workspaceId: entry.workspaceId,
            agentName: entry.agentName,
            connectionId: entry.connectionId,
            opensSourceWindow: opensSeparateBackendWindows
        ) { onSwitchConnection(id: $0) }
    }
}
