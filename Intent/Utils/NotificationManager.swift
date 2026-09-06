import SwiftUI
import Observation
import AudioToolbox
import UserNotifications

struct ToastInfo: Equatable {
    let id: UUID
    let agentId: String
    let workspaceId: String
    let agentName: String
    let workspaceName: String
    /// The pinned backend the alert came from; nil for the default session.
    let sourceBackendID: BackendID?

    init(agentId: String, workspaceId: String, agentName: String, workspaceName: String,
         sourceBackendID: BackendID? = nil) {
        self.id = UUID()
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName
        self.workspaceName = workspaceName
        self.sourceBackendID = sourceBackendID
    }
}

@MainActor
@Observable class NotificationManager {
    static let shared = NotificationManager()

    var currentToast: ToastInfo?

    /// The agent ID currently being viewed in ConversationView
    var currentAgentId: String? {
        didSet {
            if let currentAgentId,
               currentAgentId != oldValue,
               let connectionId = activeConnectionId() {
                localNotificationService.removeDeliveredNotifications(
                    forAgentId: currentAgentId, connectionId: connectionId)
            }
        }
    }

    /// The workspace ID currently being viewed (workspace detail or conversation)
    var currentWorkspaceId: String?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let localNotificationService: LocalNotificationService
    @ObservationIgnored private let applicationState: () -> UIApplication.State
    @ObservationIgnored private let presentFeedback: () -> Void
    @ObservationIgnored private let activeConnectionId: () -> UUID?
    @ObservationIgnored private let connection: ConnectionManagerRouting
    @ObservationIgnored private let workspaceStore: WorkspaceStore
    @ObservationIgnored private var agentSelectionHandler: ((String, String, String, UUID) -> Void)?
    @ObservationIgnored private var pendingNotificationResponse: LocalNotificationService.Response?

    /// Pinned sessions currently observed for cross-window alert aggregation,
    /// with the event-handler id registered on each session's connection.
    @ObservationIgnored private var observedSessions:
        [BackendID: (session: BackendSession, handlerId: UUID)] = [:]

    init(
        localNotificationService: LocalNotificationService = .shared,
        applicationState: @escaping () -> UIApplication.State = {
            UIApplication.shared.applicationState
        },
        activeConnectionId: @escaping () -> UUID? = {
            PersistenceManager.shared.activeConnection()?.id
        },
        presentFeedback: @escaping () -> Void = {
            HapticManager.notification(.success)
            AudioServicesPlaySystemSound(1152)
        },
        connection: ConnectionManagerRouting = ConnectionManager.shared,
        workspaceStore: WorkspaceStore = WorkspaceStore.shared,
        registerEvents: Bool = true
    ) {
        self.localNotificationService = localNotificationService
        self.applicationState = applicationState
        self.activeConnectionId = activeConnectionId
        self.presentFeedback = presentFeedback
        self.connection = connection
        self.workspaceStore = workspaceStore
        localNotificationService.onWillPresentNotification = { [weak self] response in
            self?.handleForegroundNotification(response)
        }
        localNotificationService.onNotificationResponse = { [weak self] response in
            self?.handleNotificationResponse(response)
        }
        localNotificationService.requestAuthorizationIfNeeded()
        if registerEvents { registerEventHandler() }
    }

    func setAgentSelectionHandler(_ handler: @escaping (String, String, String, UUID) -> Void) {
        agentSelectionHandler = handler
        if let pendingNotificationResponse {
            self.pendingNotificationResponse = nil
            routeNotificationResponse(pendingNotificationResponse)
        }
    }

    func handleNotificationResponse(_ response: LocalNotificationService.Response) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.agentId != nil, response.workspaceId != nil, response.agentName != nil,
              let connectionId = response.connectionId,
              connectionId == activeConnectionId()
        else { return }

        guard agentSelectionHandler != nil else {
            pendingNotificationResponse = response
            return
        }
        routeNotificationResponse(response)
    }

    private func routeNotificationResponse(_ response: LocalNotificationService.Response) {
        guard let agentId = response.agentId,
              let workspaceId = response.workspaceId,
              let agentName = response.agentName,
              let connectionId = response.connectionId,
              connectionId == activeConnectionId()
        else { return }
        agentSelectionHandler?(agentId, workspaceId, agentName, connectionId)
    }

    private func handleForegroundNotification(_ response: LocalNotificationService.Response) {
        guard let agentId = response.agentId,
              let workspaceId = response.workspaceId,
              let agentName = response.agentName,
              let connectionId = response.connectionId,
              connectionId == activeConnectionId()
        else { return }
        presentForegroundAlert(
            agentId: agentId, workspaceId: workspaceId, agentName: agentName)
    }

    private func registerEventHandler() {
        AppLog.notifications.debug("[NotificationManager] Registering event handler")
        connection.onEvent { [weak self] method, params in
            Task { @MainActor in
                self?.handleEvent(params, from: nil)
            }
        }
    }

    // MARK: - Cross-session aggregation

    /// Observe a pinned session's connection so its agents alert too. The
    /// default session's connection is already observed from init, so
    /// attaching the default session — or an already-observed backend — is
    /// a no-op. Wired to `BackendSessionRegistry.onSessionCreated`.
    func attachSessionObserver(for session: BackendSession) {
        guard let backendID = session.pinnedBackendID else { return }
        guard observedSessions[backendID] == nil else { return }
        let handlerId = session.connection.onEvent { [weak self] _, params in
            Task { @MainActor in
                self?.handleEvent(params, from: backendID)
            }
        }
        observedSessions[backendID] = (session, handlerId)
    }

    /// Stop observing a pinned session's connection. Wired to
    /// `BackendSessionRegistry.onSessionTeardown`; extra detaches are no-ops.
    func detachSessionObserver(for backendID: BackendID) {
        guard let observed = observedSessions.removeValue(forKey: backendID) else { return }
        observed.session.connection.removeEventHandler(id: observed.handlerId)
    }

    private func handleEvent(_ params: Any, from sourceBackendID: BackendID?) {
        // Debug: log raw params type and keys
        AppLog.notifications.debug("[NotificationManager] handleEvent called, params type=\(type(of: params))")
        guard let dict = params as? [String: Any] else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ params is not [String: Any], skipping")
            return
        }
        AppLog.notifications.debug("[NotificationManager] dict keys: \(dict.keys.sorted())")

        // Unwrap event from subscription wrapper
        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
            AppLog.notifications.debug("[NotificationManager] Unwrapped inner event, keys: \(event.keys.sorted())")
        } else {
            event = dict
            AppLog.notifications.debug("[NotificationManager] No inner event wrapper, using dict directly")
        }

        let eventType = event["type"] as? String
        AppLog.notifications.debug("[NotificationManager] Event type: \(eventType ?? "nil")")

        guard eventType == "agent:idle" else { return }

        guard let data = event["data"] as? [String: Any] else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ agent:idle missing 'data' dict. Event keys: \(event.keys.sorted())")
            return
        }
        guard let agentId = data["agentId"] as? String else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ agent:idle data missing 'agentId'. Data keys: \(data.keys.sorted())")
            return
        }
        guard let workspaceId = event["workspaceId"] as? String else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ agent:idle missing 'workspaceId'. Event keys: \(event.keys.sorted())")
            return
        }
        // Resolve the connection identity of the event's source. A pinned
        // session on the backend the default connection already tracks
        // would double-alert (both sockets receive the event) — the default
        // handler wins and the pinned duplicate is dropped.
        let connectionId: UUID
        if let sourceBackendID {
            guard sourceBackendID.connectionID != activeConnectionId() else { return }
            connectionId = sourceBackendID.connectionID
        } else {
            guard let active = activeConnectionId() else { return }
            connectionId = active
        }

        // Emit-time fast paths: background agents and agents the payload
        // already marks as waiting on sub-agents never alert.
        AppLog.notifications.debug("[NotificationManager] agent:idle — agentId=\(agentId), currentAgentId=\(currentAgentId ?? "nil")")
        if Self.shouldSkipIdleEventFastPath(data) { return }

        let agentName = data["agentName"] as? String
            ?? event["actor"].flatMap { ($0 as? [String: Any])?["name"] as? String }
            ?? "Agent"

        // Fresh agent.list read (desktop parity): suppress when the idle agent
        // is still waiting on delegated sub-agents, another agent is active, or
        // the idle agent is background per metadata. Fail-open on read failure.
        Task { @MainActor [weak self] in
            let agents = await self?.fetchWorkspaceAgents(
                workspaceId: workspaceId, from: sourceBackendID)
            guard let self,
                  self.sourceStillCurrent(sourceBackendID, connectionId: connectionId)
            else { return }
            if Self.shouldSuppressIdleAlert(idleAgentId: agentId, agents: agents) {
                AppLog.notifications.debug("[NotificationManager] Suppressing idle alert — workspace still active or awaited")
                return
            }
            self.presentIdleAlert(
                agentId: agentId, workspaceId: workspaceId,
                agentName: agentName, connectionId: connectionId,
                sourceBackendID: sourceBackendID)
        }
    }

    /// Whether the event's source is still live: the default session must
    /// still be on the same active connection; a pinned session must still
    /// be observed (not torn down mid-flight).
    private func sourceStillCurrent(_ sourceBackendID: BackendID?, connectionId: UUID) -> Bool {
        if let sourceBackendID { return observedSessions[sourceBackendID] != nil }
        return activeConnectionId() == connectionId
    }

    /// The workspace store owning the event source's rows: the pinned
    /// session's store, or the default (injected) store.
    private func workspaceStore(for sourceBackendID: BackendID?) -> WorkspaceStore {
        guard let sourceBackendID,
              let observed = observedSessions[sourceBackendID] else { return workspaceStore }
        return observed.session.workspaceStore
    }

    /// Emit-time fast path over the raw `agent:idle` payload: skip background
    /// agents, and agents the daemon already marks as waiting on sub-agents.
    nonisolated static func shouldSkipIdleEventFastPath(_ data: [String: Any]) -> Bool {
        if data["isBackground"] as? Bool ?? false { return true }
        if data["isWaitingForOtherAgents"] as? Bool ?? false { return true }
        if let waitingIds = data["waitingForAgentIds"] as? [String], !waitingIds.isEmpty { return true }
        return false
    }

    /// Pure suppress-or-alert decision over a fresh `agent.list` read.
    /// `agents == nil` means the read failed — fail open (alert).
    ///
    /// The waiting-on-children gate is an iOS extension beyond the desktop
    /// port (desktop only honors the emit-time flag). It is safe because the
    /// list read can only under-suppress relative to the emit-time flag (a
    /// consumed watch clears the flag), and over-suppression self-heals: the
    /// awaited child's completion wakes the parent, whose next turn emits a
    /// fresh `agent:idle` with the flag cleared.
    ///
    /// The other-agents gate uses the canonical `AgentSession.isActive`
    /// predicate so status-only active agents suppress premature completion alerts.
    static func shouldSuppressIdleAlert(idleAgentId: String, agents: [AgentSession]?) -> Bool {
        guard let agents else { return false }
        if let idleAgent = agents.first(where: { $0.id == idleAgentId }) {
            if idleAgent.isBackground { return true }
            if idleAgent.isWaitingForOtherAgents || !idleAgent.waitingForAgentIds.isEmpty { return true }
        }
        return agents.contains { agent in
            agent.id != idleAgentId && agent.isActive
        }
    }

    /// Fetches the workspace's agents for the suppression decision over the
    /// event source's own connection. Returns nil when the source session is
    /// gone, the read fails, or the response is malformed.
    private func fetchWorkspaceAgents(
        workspaceId: String, from sourceBackendID: BackendID?
    ) async -> [AgentSession]? {
        let sourceConnection: ConnectionManagerRouting
        if let sourceBackendID {
            guard let observed = observedSessions[sourceBackendID] else { return nil }
            sourceConnection = observed.session.connection
        } else {
            sourceConnection = connection
        }
        do {
            let result = try await sourceConnection.request(
                "agent.list",
                params: ["workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let items = dict["agents"] as? [[String: Any]] {
                return items.compactMap { AgentSession.parseAgent($0) }
            }
            return nil
        } catch {
            AppLog.notifications.warning("[NotificationManager] agent.list failed, falling back to alert: \(error)")
            return nil
        }
    }

    func presentIdleAlert(agentId: String, workspaceId: String, agentName: String) {
        guard let connectionId = activeConnectionId() else { return }
        presentIdleAlert(
            agentId: agentId, workspaceId: workspaceId,
            agentName: agentName, connectionId: connectionId, sourceBackendID: nil)
    }

    private func presentIdleAlert(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connectionId: UUID,
        sourceBackendID: BackendID?
    ) {
        guard sourceStillCurrent(sourceBackendID, connectionId: connectionId) else { return }
        // Look up workspace name in the source session's store
        let workspaceName = workspaceStore(for: sourceBackendID).workspaces
            .first(where: { $0.id == workspaceId })?.title ?? "Workspace"

        guard applicationState() == .active else {
            localNotificationService.postAgentIdleNotification(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                workspaceName: workspaceName,
                connectionId: connectionId
            )
            return
        }

        presentForegroundAlert(
            agentId: agentId, workspaceId: workspaceId,
            agentName: agentName, workspaceName: workspaceName,
            sourceBackendID: sourceBackendID)
    }

    private func presentForegroundAlert(
        agentId: String,
        workspaceId: String,
        agentName: String,
        workspaceName: String? = nil,
        sourceBackendID: BackendID? = nil
    ) {
        let workspaceName = workspaceName ?? workspaceStore(for: sourceBackendID).workspaces
            .first(where: { $0.id == workspaceId })?.title ?? "Workspace"
        if agentId == currentAgentId {
            // Currently viewing this exact agent's conversation — haptic + sound, no toast
            presentFeedback()
        } else if workspaceId == currentWorkspaceId {
            // Viewing this workspace (agent list) — haptic + sound, no toast
            // The agent list will update via events, so the user will see the change
            presentFeedback()
        } else {
            // Different workspace — haptic + sound + toast
            presentFeedback()
            showToast(agentId: agentId, workspaceId: workspaceId,
                      agentName: agentName, workspaceName: workspaceName,
                      sourceBackendID: sourceBackendID)
        }
    }

    private func showToast(agentId: String, workspaceId: String,
                           agentName: String, workspaceName: String,
                           sourceBackendID: BackendID? = nil) {
        dismissTask?.cancel()

        withAnimation(.spring(
            response: Constants.Notification.presentationSpringResponse,
            dampingFraction: Constants.Notification.presentationSpringDamping
        )) {
            currentToast = ToastInfo(
                agentId: agentId, workspaceId: workspaceId,
                agentName: agentName, workspaceName: workspaceName,
                sourceBackendID: sourceBackendID)
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: Constants.Notification.displayDuration)
            guard !Task.isCancelled else { return }
            dismissToast()
        }
    }

    func dismissToast() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: Constants.Notification.dismissalAnimationDuration)) {
            currentToast = nil
        }
    }
}

