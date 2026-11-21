import Foundation
import UserNotifications

extension NotificationManager {
    // MARK: - Selection handlers (per-backend windows)

    @discardableResult
    func registerAgentSelectionHandler(
        for backendID: BackendID,
        _ handler: @escaping (String, String, String, UUID) -> Void
    ) -> UUID {
        let token = UUID()
        agentSelectionHandlers[backendID] = (token, handler)
        if let pending = pendingAgentSelection {
            pendingAgentSelection = nil
            routeAgentSelection(
                agentId: pending.agentId,
                workspaceId: pending.workspaceId,
                agentName: pending.agentName,
                connectionId: pending.connectionId
            )
        }
        return token
    }

    func removeAgentSelectionHandler(for backendID: BackendID, token: UUID) {
        guard agentSelectionHandlers[backendID]?.token == token else { return }
        agentSelectionHandlers[backendID] = nil
    }

    func handleNotificationResponse(_ response: LocalNotificationService.Response) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let agentId = response.agentId,
              let workspaceId = response.workspaceId,
              let agentName = response.agentName,
              let connectionId = response.connectionId
        else { return }
        routeAgentSelection(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            connectionId: connectionId
        )
    }

    func routeAgentSelection(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connectionId: UUID
    ) {
        let source = BackendID(connectionId)
        switch Self.selectionRoute(
            source: source,
            registeredBackends: Set(agentSelectionHandlers.keys),
            supportsMultipleWindows: supportsMultipleWindows
        ) {
        case .deliverToWindow:
            pendingAgentSelection = nil
            agentSelectionHandlers[source]?.handler(
                agentId,
                workspaceId,
                agentName,
                connectionId
            )
        case .openSourceWindow:
            pendingAgentSelection = PendingAgentSelection(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                connectionId: connectionId
            )
            openBackendWindow?(source)
        case .holdForFirstWindow:
            pendingAgentSelection = PendingAgentSelection(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                connectionId: connectionId
            )
        case .drop:
            pendingAgentSelection = nil
        }
    }

    func routeHistorySelection(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connectionId: UUID,
        opensSourceWindow: Bool = WindowRetargetRoute.platformOpensSeparateBackendWindows,
        switchWindow: (UUID) -> Void
    ) {
        let route = Self.selectionRoute(
            source: BackendID(connectionId),
            registeredBackends: Set(agentSelectionHandlers.keys),
            supportsMultipleWindows: supportsMultipleWindows
        )
        guard route == .drop || (route == .openSourceWindow && !opensSourceWindow) else {
            routeAgentSelection(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                connectionId: connectionId
            )
            return
        }
        pendingAgentSelection = PendingAgentSelection(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            connectionId: connectionId
        )
        switchWindow(connectionId)
    }

    // MARK: - Tap routing (spec decision 5)

    enum SelectionRoute: Equatable {
        case deliverToWindow
        case openSourceWindow
        case holdForFirstWindow
        case drop
    }

    nonisolated static func selectionRoute(
        source: BackendID,
        registeredBackends: Set<BackendID>,
        supportsMultipleWindows: Bool
    ) -> SelectionRoute {
        if registeredBackends.contains(source) { return .deliverToWindow }
        if supportsMultipleWindows { return .openSourceWindow }
        return registeredBackends.isEmpty ? .holdForFirstWindow : .drop
    }

    // MARK: - Presentation routing (per-backend windows)

    nonisolated static func windowPresentsAlert(
        source: BackendID,
        windowBackendID: BackendID?,
        supportsMultipleWindows: Bool
    ) -> Bool {
        guard supportsMultipleWindows else { return true }
        return windowBackendID == source
    }

    nonisolated static func alertPresents(
        source: BackendID,
        registeredBackends: Set<BackendID>,
        supportsMultipleWindows: Bool
    ) -> Bool {
        guard supportsMultipleWindows else { return true }
        return registeredBackends.contains(source)
    }
}
