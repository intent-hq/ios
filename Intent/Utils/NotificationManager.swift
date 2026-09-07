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
    /// The backend the alert came from (window model v2: every alert has a
    /// concrete source connection, so taps can route to its window).
    let sourceBackendID: BackendID

    init(agentId: String, workspaceId: String, agentName: String, workspaceName: String,
         sourceBackendID: BackendID) {
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

    /// Agent conversations currently on screen, keyed by their session's
    /// connection id. Counted (multiset): two windows on the same backend
    /// can show the same conversation, and closing one must not stop
    /// suppressing alerts for the surface still visible in the sibling.
    @ObservationIgnored private var openAgentIds: [UUID: [String: Int]] = [:]

    /// Workspace details currently on screen, keyed by connection id.
    /// Counted for the same sibling-window reason as `openAgentIds`.
    @ObservationIgnored private var openWorkspaceIds: [UUID: [String: Int]] = [:]

    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let localNotificationService: LocalNotificationService
    @ObservationIgnored private let applicationState: () -> UIApplication.State
    @ObservationIgnored private let presentFeedback: () -> Void
    @ObservationIgnored private let activeConnectionId: () -> UUID?
    @ObservationIgnored private let connection: ConnectionManagerRouting
    @ObservationIgnored private let workspaceStore: WorkspaceStore

    /// Per-window agent-selection handlers, keyed by the window's bound
    /// backend (window model v2: no global last-window-wins handler). The
    /// registration token lets a disappearing window remove only its own
    /// registration, never a successor's.
    @ObservationIgnored private var agentSelectionHandlers:
        [BackendID: (token: UUID, handler: (String, String, String, UUID) -> Void)] = [:]

    /// Opens — or raises — the window bound to a backend via
    /// `openWindow(value:)`. Set by window roots where multiple windows are
    /// supported.
    @ObservationIgnored var openBackendWindow: ((BackendID) -> Void)?

    /// Whether the platform supports multiple windows (visionOS, iPad). Set
    /// by window roots from `\.supportsMultipleWindows`.
    @ObservationIgnored var supportsMultipleWindows = false

    /// A tapped alert held until its source backend's window registers a
    /// handler (cold start, or a just-opened window still binding).
    @ObservationIgnored private var pendingAgentSelection:
        (agentId: String, workspaceId: String, agentName: String, connectionId: UUID)?

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

    // MARK: - Window visibility (connection-scoped)

    /// A conversation became visible in some window: suppress its toasts
    /// and clear any delivered system notification for the same agent on
    /// the same backend — never another backend's same-id agent.
    func conversationOpened(agentId: String, connectionId: UUID) {
        openAgentIds[connectionId, default: [:]][agentId, default: 0] += 1
        localNotificationService.removeDeliveredNotifications(
            forAgentId: agentId, connectionId: connectionId)
    }

    /// Balances `conversationOpened`. Keyed by (agent, connection), so a
    /// parent conversation's disappear never clobbers a pushed child's —
    /// or another window's — visibility.
    func conversationClosed(agentId: String, connectionId: UUID) {
        decrement(&openAgentIds, id: agentId, connectionId: connectionId)
    }

    /// A workspace detail became visible in some window.
    func workspaceOpened(workspaceId: String, connectionId: UUID) {
        openWorkspaceIds[connectionId, default: [:]][workspaceId, default: 0] += 1
    }

    /// Balances `workspaceOpened`.
    func workspaceClosed(workspaceId: String, connectionId: UUID) {
        decrement(&openWorkspaceIds, id: workspaceId, connectionId: connectionId)
    }

    private func decrement(
        _ counts: inout [UUID: [String: Int]], id: String, connectionId: UUID
    ) {
        guard let count = counts[connectionId]?[id] else { return }
        counts[connectionId]?[id] = count > 1 ? count - 1 : nil
    }

    private func isAgentOpen(_ agentId: String, connectionId: UUID) -> Bool {
        (openAgentIds[connectionId]?[agentId] ?? 0) > 0
    }

    private func isWorkspaceOpen(_ workspaceId: String, connectionId: UUID) -> Bool {
        (openWorkspaceIds[connectionId]?[workspaceId] ?? 0) > 0
    }

    // MARK: - Selection handlers (per-backend windows)

    /// Registers the selection handler for one backend's window; a later
    /// registration for the same backend replaces the earlier one (windows
    /// sharing a backend navigate it identically). A held cold-start tap is
    /// re-routed immediately. Returns the token for
    /// `removeAgentSelectionHandler`.
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
                agentId: pending.agentId, workspaceId: pending.workspaceId,
                agentName: pending.agentName, connectionId: pending.connectionId)
        }
        return token
    }

    /// Removes a backend's handler if `token` still owns the registration,
    /// so a stale window's teardown never removes its replacement's.
    func removeAgentSelectionHandler(for backendID: BackendID, token: UUID) {
        guard agentSelectionHandlers[backendID]?.token == token else { return }
        agentSelectionHandlers[backendID] = nil
    }

    // System-notification taps and toast taps share one policy
    // (`routeAgentSelection`): the tap lands on the source backend's own
    // window, never on whichever window happened to render it.
    func handleNotificationResponse(_ response: LocalNotificationService.Response) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let agentId = response.agentId,
              let workspaceId = response.workspaceId,
              let agentName = response.agentName,
              let connectionId = response.connectionId
        else { return }
        routeAgentSelection(
            agentId: agentId, workspaceId: workspaceId,
            agentName: agentName, connectionId: connectionId)
    }

    /// Routes a tapped agent alert to the window bound to its source
    /// backend: deliver when that window is registered, open/raise it where
    /// multiple windows are supported (delivery completes when it
    /// registers), hold a cold-start tap for the first window, and drop
    /// cross-backend taps on single-window platforms — the same visible
    /// behavior as the old coordinator-side connection guard.
    func routeAgentSelection(
        agentId: String, workspaceId: String, agentName: String, connectionId: UUID
    ) {
        let source = BackendID(connectionId)
        switch Self.selectionRoute(
            source: source,
            registeredBackends: Set(agentSelectionHandlers.keys),
            supportsMultipleWindows: supportsMultipleWindows)
        {
        case .deliverToWindow:
            pendingAgentSelection = nil
            agentSelectionHandlers[source]?.handler(
                agentId, workspaceId, agentName, connectionId)
        case .openSourceWindow:
            pendingAgentSelection = (agentId, workspaceId, agentName, connectionId)
            openBackendWindow?(source)
        case .holdForFirstWindow:
            pendingAgentSelection = (agentId, workspaceId, agentName, connectionId)
        case .drop:
            pendingAgentSelection = nil
        }
    }

    // MARK: - Tap routing (spec decision 5)

    /// Where a tapped agent alert (toast or system notification) goes.
    enum SelectionRoute: Equatable {
        /// The source backend has a registered window: deliver to it.
        case deliverToWindow
        /// No window shows the source backend, but the platform can open
        /// one: open/raise it and hold the tap until it registers.
        case openSourceWindow
        /// No window has registered yet (cold start): hold the tap for the
        /// first window, which delivers or drops it on registration.
        case holdForFirstWindow
        /// A single-window platform is showing another backend: drop the
        /// tap.
        case drop
    }

    /// Pure routing decision for a tapped alert under window model v2:
    /// every alert carries its source backend's connection id, and the tap
    /// belongs to that backend's window.
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

    /// Pure per-window presentation decision: on multi-window platforms a
    /// toast renders only in the window bound to its source backend — a
    /// window on another backend (or a pairing window with no backend)
    /// shows nothing. Single-window platforms render every toast, keeping
    /// iPhone behavior unchanged.
    nonisolated static func windowPresentsAlert(
        source: BackendID,
        windowBackendID: BackendID?,
        supportsMultipleWindows: Bool
    ) -> Bool {
        guard supportsMultipleWindows else { return true }
        return windowBackendID == source
    }

    /// Pure manager-level decision: whether a foreground alert presents at
    /// all. On multi-window platforms feedback plays and the toast is
    /// stored only when the source backend's window is registered — the
    /// one window that would render it (`windowPresentsAlert`); otherwise
    /// the alert would be invisible yet clobber another backend's visible
    /// toast. Single-window platforms always present (unchanged iPhone
    /// behavior).
    nonisolated static func alertPresents(
        source: BackendID,
        registeredBackends: Set<BackendID>,
        supportsMultipleWindows: Bool
    ) -> Bool {
        guard supportsMultipleWindows else { return true }
        return registeredBackends.contains(source)
    }

    private func handleForegroundNotification(_ response: LocalNotificationService.Response) {
        guard let agentId = response.agentId,
              let workspaceId = response.workspaceId,
              let agentName = response.agentName,
              let connectionId = response.connectionId
        else { return }
        presentForegroundAlert(
            agentId: agentId, workspaceId: workspaceId, agentName: agentName,
            connectionId: connectionId)
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

    /// Observe a backend session's connection so its agents alert too.
    /// Attaching a transient pairing session (no backend) or an
    /// already-observed backend is a no-op. Wired to
    /// `BackendSessionRegistry.onSessionCreated`.
    func attachSessionObserver(for session: BackendSession) {
        guard let backendID = session.backendID else { return }
        guard observedSessions[backendID] == nil else { return }
        let handlerId = session.connection.onEvent { [weak self] _, params in
            Task { @MainActor in
                self?.handleEvent(params, from: backendID)
            }
        }
        observedSessions[backendID] = (session, handlerId)
    }

    /// Stop observing a backend session's connection. Wired to
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
        // Resolve the connection identity of the event's source session
        // (window model v2: every backend session is observed directly —
        // there is no default handler to deduplicate against). The nil
        // source (legacy init-registered handler) maps to the last-used
        // pointer.
        let connectionId: UUID
        if let sourceBackendID {
            connectionId = sourceBackendID.connectionID
        } else {
            guard let active = activeConnectionId() else { return }
            connectionId = active
        }

        // Emit-time fast paths: background agents and agents the payload
        // already marks as waiting on sub-agents never alert.
        AppLog.notifications.debug("[NotificationManager] agent:idle — agentId=\(agentId)")
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
            connectionId: connectionId)
    }

    // Suppression is connection-scoped (window model v2): only the SAME
    // backend's open conversation/workspace downgrades its alert to
    // feedback — an identically-named id open on another backend's window
    // still toasts. The toast is tagged with the concrete source backend
    // (`workspaceStore(for:)` falls back to the default store when the
    // source isn't an observed session — the legacy handler path).
    // Presentation is window-scoped: on multi-window platforms the alert
    // (feedback and toast alike) presents only via the source backend's
    // window (`alertPresents`); other windows see and hear nothing.
    private func presentForegroundAlert(
        agentId: String,
        workspaceId: String,
        agentName: String,
        workspaceName: String? = nil,
        connectionId: UUID
    ) {
        let sourceBackendID = BackendID(connectionId)
        guard Self.alertPresents(
            source: sourceBackendID,
            registeredBackends: Set(agentSelectionHandlers.keys),
            supportsMultipleWindows: supportsMultipleWindows)
        else { return }
        let workspaceName = workspaceName ?? workspaceStore(for: sourceBackendID).workspaces
            .first(where: { $0.id == workspaceId })?.title ?? "Workspace"
        if isAgentOpen(agentId, connectionId: connectionId) {
            // Currently viewing this exact agent's conversation — haptic + sound, no toast
            presentFeedback()
        } else if isWorkspaceOpen(workspaceId, connectionId: connectionId) {
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
                           sourceBackendID: BackendID) {
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

