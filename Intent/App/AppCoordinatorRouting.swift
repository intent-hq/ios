import Foundation

/// Classification of an incoming `intent://` URL by its URI host. Pure so
/// the routing can be unit-tested without a coordinator; the URL is never
/// logged since pair payloads carry the auth token and invite payloads a
/// single-use secret.
enum IncomingDeepLink: Equatable {
    /// An `intent://invite` link. Invites are redeemed on the desktop only in
    /// v1; iOS surfaces a notice and never parses or redeems the payload.
    case invite
    /// A well-formed `intent://pair` payload.
    case pair(PairingPayload)
    /// Any other or malformed `intent://` URL.
    case unhandled

    static func classify(_ url: URL) -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "intent" else {
            return .unhandled
        }
        if components.host == "invite" {
            return .invite
        }
        if let payload = PairingPayload.parse(url.absoluteString) {
            return .pair(payload)
        }
        return .unhandled
    }
}

final class AppCoordinatorRoutingState {
    struct PendingNotificationSelection {
        let agentId: String
        let workspaceId: String
        let agentName: String
        let connectionId: UUID
    }

    var hasLoadCompleted = false
    var stashedDeepLinkPayload: PairingPayload?
    var stashedInviteNotice = false
    var pendingNotificationSelection: PendingNotificationSelection?
}

extension AppCoordinator {
    func onLoadComplete() {
        routingState.hasLoadCompleted = true
        refreshSyncedBackends()
        if DemoMode.pretendPaired || backendID != nil {
            currentScreen = .connecting
        } else {
            // Synced connections merged from the registry (or connections
            // saved earlier) must be offered on the pairing surface.
            pairingShowsSavedConnections = !dependencies.persistence.loadConnections().isEmpty
            currentScreen = .pairing
        }
        // A deep link that arrived during the cold-start load is surfaced
        // now, over whichever screen the load routed to.
        if let payload = routingState.stashedDeepLinkPayload {
            routingState.stashedDeepLinkPayload = nil
            pendingDeepLinkPairing = DeepLinkPairingRequest(payload: payload)
        }
        if routingState.stashedInviteNotice {
            routingState.stashedInviteNotice = false
            isInviteNoticePresented = true
        }
    }

    // MARK: - Deep links (intent:// URLs)

    /// Entry point for `intent://` URLs (IntentApp.onOpenURL). Only
    /// `intent://pair` URIs are actionable: they surface a confirmation
    /// (DeepLinkPairingView) before any connection is attempted.
    /// `intent://invite` links are desktop-only in v1: they surface a notice
    /// and pair nothing. Every other or malformed `intent://` URL is ignored
    /// without disturbing app state. The URL itself is never logged — pair
    /// payloads carry the auth token and invite payloads a single-use secret.
    func handleIncomingURL(_ url: URL) {
        switch IncomingDeepLink.classify(url) {
        case .pair(let payload):
            guard routingState.hasLoadCompleted else {
                // Cold start: the URL can arrive before onLoadComplete has routed
                // to the first screen — stash it and surface it after load.
                routingState.stashedDeepLinkPayload = payload
                return
            }
            pendingDeepLinkPairing = DeepLinkPairingRequest(payload: payload)
        case .invite:
            AppLog.app.info("[AppCoordinator] Invite deep link received; invites are desktop-only")
            guard routingState.hasLoadCompleted else {
                routingState.stashedInviteNotice = true
                return
            }
            isInviteNoticePresented = true
        case .unhandled:
            AppLog.app.info("[AppCoordinator] Ignoring non-pairing deep link")
        }
    }

    /// A deep-link pairing connected and persisted successfully.
    ///
    /// A re-pair of this window's own backend (same record id, e.g. a
    /// rotated token) restarts this window's attempt so it dials the
    /// refreshed record. Any other pairing routes to the new backend via
    /// onPaired: the window root's retarget hook applies the v2 policy
    /// (rebind in place on single-window platforms; open/raise the new
    /// backend's window — or replace an unbound pairing window with it —
    /// where multiple windows are supported).
    func onDeepLinkPaired(_ connection: StoredConnection) {
        pendingDeepLinkPairing = nil
        if let bound = backendID, bound.connectionID == connection.id {
            dependencies.connection.updateCachedCredentials(
                hosts: connection.server.hosts,
                port: connection.server.port,
                token: connection.token,
                certFingerprint: connection.server.certFingerprint,
                tcAddress: connection.server.tcAddress
            )
            restartConnectionAttempt()
            return
        }
        onPaired(connection)
    }

    /// A pairing completed over this window's session (QR scan, manual
    /// entry, or deep link for another backend): route to the paired
    /// backend's window. The window root's retarget hook applies the
    /// v2 policy (rebind in place vs open/raise); without a hook (tests,
    /// previews) the pairing session's live connection is used in place.
    func onPaired(_ connection: StoredConnection) {
        if let retargetWindow {
            let target = BackendID(connection.id)
            retargetWindow(target)
            // The pairing dialed the new backend over THIS window's live
            // session connection. Where multiple windows are supported the
            // retarget opened/raised the target's own window and this window
            // keeps its binding — re-dial its own backend or it keeps showing
            // the newly paired daemon's data over the hijacked socket. On
            // single-window platforms the retarget rebinds this window in
            // place (session torn down and replaced), so the repair state is
            // discarded with the old session.
            if let bound = backendID, bound != target {
                redialWindowBackend()
            }
            return
        }
        if case .pairing = currentScreen {
            pairingShowsSavedConnections = false
            onConnectionSuccess()
        } else {
            onSwitchConnection(id: connection.id)
        }
    }

    /// The connection identity this window shows: the bound backend's, if
    /// any.
    var windowConnectionID: UUID? {
        backendID?.connectionID
    }

    /// The saved connection record this window shows: the bound backend's
    /// record. Settings renders it and Log Off forgets it — always scoped
    /// to this window's backend, never a global pointer.
    var windowConnection: StoredConnection? {
        guard let backendID else { return nil }
        return dependencies.persistence.loadConnections().first { $0.id == backendID.connectionID }
    }

    /// Routes notification taps immediately once the connected UI is stable,
    /// or stashes them until cold-start connection routing completes. Taps
    /// for a backend this window doesn't show are dropped (the multi-window
    /// tap route opens the source backend's own window instead).
    func handleNotificationSelection(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connectionId: UUID
    ) {
        guard windowConnectionID == connectionId else { return }
        switch currentScreen {
        case .loading, .connecting, .pairing, .connectionFailed, .disconnected:
            routingState.pendingNotificationSelection = .init(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                connectionId: connectionId
            )
        default:
            onSelectAgent(agentId, workspaceId: workspaceId, agentName: agentName)
        }
    }

    /// Called when the scene becomes active (launch and every return to the
    /// foreground): re-merges the iCloud-synced backend registry so changes
    /// made on other devices while the app was backgrounded show up.
    func onScenePhaseActive() {
        dependencies.backgroundTaskManager.endIfNeeded()
        refreshSyncedBackends()
    }

    /// Called when the scene leaves the foreground so agent-completion events
    /// can continue arriving during iOS's extended background execution window.
    func onScenePhaseNotActive() {
        dependencies.backgroundTaskManager.beginIfNeeded()
    }

    /// Merges the iCloud-synced backend registry into the saved connections
    /// (see `SyncedBackendConnectionMerge`). An unavailable registry read
    /// (locked keychain, missing entitlement) is a no-op — existing local
    /// knowledge is kept. When a tombstone removes this window's backend,
    /// disconnects and routes away like Log Off (the window root's removal
    /// observation closes or rebinds the window). When the merge rewrote
    /// this window's record (rotated token, new routes), the live
    /// ConnectionManager cache adopts the new fields so the next reconnect
    /// uses them.
    @discardableResult
    func refreshSyncedBackends() -> SyncedBackendMergeOutcome? {
        guard case .available(let records) = dependencies.syncedRegistry.listBackends() else { return nil }
        let windowID = windowConnectionID
        let outcome = dependencies.persistence.mergeSyncedBackends(records: records)
        savedConnectionsUndecodable = outcome.registryUndecodable
        if outcome.registryUndecodable {
            AppLog.app.error(
                "[AppCoordinator] Saved connections could not be decoded; synced merge skipped to preserve them"
            )
            return outcome
        }
        // Tombstones close windows on the removed backends; a re-added
        // record (same id resurrected from another device) clears its mark.
        dependencies.sessionRegistry.markBackendsRemoved(outcome.removedIds.map(BackendID.init))
        dependencies.sessionRegistry.clearRemovedMarks(outcome.addedIds.map(BackendID.init))
        for removedId in outcome.removedIds {
            dependencies.persistence.clearLastScreen(for: removedId)
        }
        if let windowID, outcome.removedIds.contains(windowID) {
            exitRemovedBackend()
        } else if outcome.changed {
            if let record = windowConnection,
                outcome.updatedIds.contains(record.id) {
                dependencies.connection.updateCachedCredentials(
                    hosts: record.server.hosts,
                    port: record.server.port,
                    token: record.token,
                    certFingerprint: record.server.certFingerprint,
                    tcAddress: record.server.tcAddress
                )
            }
            // A merge while the pairing surface is up must (un)offer the
            // saved connections it added/removed.
            if case .pairing = currentScreen {
                pairingShowsSavedConnections = !dependencies.persistence.loadConnections().isEmpty
            }
        }
        return outcome
    }

    func onConnectionSuccess() {
        if routePendingNotificationSelection() { return }
        if restoreLastScreenIfAvailable() { return }
        currentScreen = .workspaceList
    }

    private func routePendingNotificationSelection() -> Bool {
        guard let selection = routingState.pendingNotificationSelection else { return false }
        routingState.pendingNotificationSelection = nil
        guard windowConnectionID == selection.connectionId else { return false }
        onSelectAgent(
            selection.agentId,
            workspaceId: selection.workspaceId,
            agentName: selection.agentName
        )
        return true
    }

    func onConnectionFailed(error: String) {
        routeToConnectionFailure(error: error, retryPolicy: .automaticConnection)
    }

    func onRetryConnection() {
        currentScreen = .connecting
    }

    func onReconnect() {
        pairingShowsSavedConnections = !dependencies.persistence.loadConnections().isEmpty
        currentScreen = .pairing
    }

    /// Drop the previous daemon's workspace data so no stale rows are shown
    /// after reconnecting, and so ConnectingView's waitForWorkspaceData
    /// (which polls lastUpdated == nil) genuinely waits for the new daemon.
    private func resetWorkspaceStore() {
        dependencies.workspaceStore.workspaces = []
        dependencies.workspaceStore.lastUpdated = nil
    }

    /// Re-dial this window's own backend after its live session connection
    /// was used to pair a different one (onPaired's bound multi-window
    /// route): drop the hijacked socket and the other daemon's workspace
    /// data, then restart the attempt — ConnectingView dials from
    /// windowConnection, this window's own saved record.
    private func redialWindowBackend() {
        lifecycleState.hasEverConnected = false
        isDisconnected = false
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        restartConnectionAttempt()
    }

    /// In-place route-out for a backend this window may no longer show —
    /// Log Off, deleting this window's connection, or a synced tombstone:
    /// drop the live connection and land on the pairing surface, offering
    /// any remaining saved connections. In the running app the window root's
    /// removal observation supersedes this (it closes the window or rebinds
    /// it to a fresh pairing session); this in-place routing covers windows
    /// without a root hook (tests, previews).
    private func exitRemovedBackend() {
        lifecycleState.hasEverConnected = false
        isDisconnected = false
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        if let connectionID = windowConnectionID {
            dependencies.persistence.clearLastScreen(for: connectionID)
        }
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = !dependencies.persistence.loadConnections().isEmpty
        currentScreen = .pairing
    }

    /// Switch this window to another saved connection. Marks the target as
    /// the last-used backend and clears its saved screen state (a switch
    /// lands on the workspace list, as before), then routes to its window
    /// via the root's retarget hook (rebind in place on single-window
    /// platforms; open/raise where multiple windows are supported). Without
    /// a hook (tests, previews) falls back to dialing in place.
    func onSwitchConnection(id: UUID) {
        dependencies.persistence.setActiveConnection(id: id)
        dependencies.persistence.clearLastScreen(for: id)
        if let retargetWindow {
            retargetWindow(BackendID(id))
            return
        }
        lifecycleState.hasEverConnected = false
        isDisconnected = false
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = false
        restartConnectionAttempt()
    }

    /// Delete a saved connection. Any window on the deleted backend —
    /// including this one — leaves it via the registry's removal mark
    /// (window model v2: the window root closes the window, or rebinds a
    /// last remaining window to the pairing surface).
    @discardableResult
    func onDeleteConnection(id: UUID) -> Bool {
        let wasThisWindows = windowConnectionID == id
        guard dependencies.persistence.deleteConnection(id: id) else {
            AppLog.app.error("[AppCoordinator] Failed to delete saved connection")
            return false
        }
        dependencies.persistence.clearLastScreen(for: id)
        dependencies.sessionRegistry.markBackendRemoved(BackendID(id))
        if wasThisWindows {
            exitRemovedBackend()
        } else if dependencies.persistence.loadConnections().isEmpty {
            pairingShowsSavedConnections = false
        }
        return true
    }

    func onOpenSettings() {
        currentScreen = .settings
    }

    /// Log Off forgets this window's backend only. Every window on the
    /// forgotten backend leaves it via the registry's removal mark (the
    /// window root closes it, or rebinds a last remaining window to the
    /// pairing surface, offering any remaining saved connections).
    @discardableResult
    func onLogOff() -> Bool {
        if let record = windowConnection {
            guard dependencies.persistence.deleteConnection(id: record.id) else {
                AppLog.app.error("[AppCoordinator] Failed to forget saved connection during log off")
                handleFailedLogOff()
                return false
            }
            dependencies.persistence.clearLastScreen(for: record.id)
            dependencies.sessionRegistry.markBackendRemoved(BackendID(record.id))
        }
        exitRemovedBackend()
        return true
    }

    /// A user-requested log off always disconnects, even when the saved record
    /// cannot be forgotten. Keep persistence-derived state intact and surface
    /// the failure instead of routing to first-run pairing.
    private func handleFailedLogOff() {
        lifecycleState.hasEverConnected = false
        isDisconnected = false
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        selectedWorkspaceId = nil
        routeToConnectionFailure(
            error: String(localized: "Could not forget this connection. Please try again."),
            retryPolicy: .manualLogOff
        )
    }
}
