import Foundation
import UserNotifications

extension NotificationManager {
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
                agentId: pending.agentId,
                workspaceId: pending.workspaceId,
                agentName: pending.agentName,
                connectionId: pending.connectionId
            )
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
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            connectionId: connectionId
        )
    }

    /// Routes a tapped agent alert to the window bound to its source
    /// backend: deliver when that window is registered, open/raise it where
    /// multiple windows are supported (delivery completes when it
    /// registers), hold a cold-start tap for the first window, and drop
    /// cross-backend taps on single-window platforms — the same visible
    /// behavior as the old coordinator-side connection guard.
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

    /// Routes an agent history tap like an alert tap, except where an alert
    /// tap would be dropped (a single window showing another backend): the
    /// selection is held, `switchWindow` moves the window to the entry's
    /// backend, and that backend's window registration delivers it.
    func routeHistorySelection(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connectionId: UUID,
        switchWindow: (UUID) -> Void
    ) {
        let route = Self.selectionRoute(
            source: BackendID(connectionId),
            registeredBackends: Set(agentSelectionHandlers.keys),
            supportsMultipleWindows: supportsMultipleWindows
        )
        guard route == .drop else {
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
}
