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

    /// Forgets a workspace reported deleted or archived, but only when the
    /// report came from this window's own device: a sheet pairing can borrow
    /// the shared socket, and transfers keep workspace ids across devices.
    func forgetHistory(ofWorkspace workspaceId: String) {
        guard let connectionID = windowConnectionID, socketReachesWindowDevice else { return }
        agentHistory.removeWorkspace(workspaceId, on: connectionID)
    }

    /// The shared socket is admitted with this window's saved credentials and
    /// no pairing attempt owns it, so its events describe this device.
    private var socketReachesWindowDevice: Bool {
        let connection = dependencies.connection
        guard connection.connectionState == .connected,
              connection.pairingAttemptID == nil,
              let admission = connection.admission,
              let saved = windowConnection else { return false }
        return admission.token == saved.token && admission.fingerprint == saved.server.certFingerprint
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
