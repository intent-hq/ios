import Foundation

final class AppCoordinatorRoutingState {
    struct PendingNotificationSelection {
        let agentId: String
        let workspaceId: String
        let agentName: String
        let connectionId: UUID
    }

    var hasLoadCompleted = false
    var stashedDeepLinkPayload: PairingPayload?
    var pendingNotificationSelection: PendingNotificationSelection?
}

extension AppCoordinator {
    func onLoadComplete() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
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
    }

    // MARK: - Deep links (intent:// URLs)

    /// Entry point for `intent://` URLs (IntentApp.onOpenURL). Only
    /// `intent://pair` URIs are actionable: they surface a confirmation
    /// (DeepLinkPairingView) before any connection is attempted. Every other
    /// or malformed `intent://` URL is ignored without disturbing app state.
    /// The URL itself is never logged — pair payloads carry the auth token.
    func handleIncomingURL(_ url: URL) {
        guard let payload = PairingPayload.parse(url.absoluteString) else {
            if url.scheme == "intent", url.host == "pair" { PairingDiagnostics.invalidInput() }
            AppLog.app.info("[AppCoordinator] Ignoring non-pairing deep link")
            return
        }
        guard routingState.hasLoadCompleted else {
            // Cold start: the URL can arrive before onLoadComplete has routed
            // to the first screen — stash it and surface it after load.
            routingState.stashedDeepLinkPayload = payload
            return
        }
        pendingDeepLinkPairing = DeepLinkPairingRequest(payload: payload)
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
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
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
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        if backendID?.connectionID == connection.id, !currentScreen.supportsConnectionLossOverlay {
            // Retargeting to the same backend does not change the window's
            // binding. Restart initial routing explicitly, including its
            // workspace-data wait, instead of leaving the failure screen up.
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
        if let retargetWindow {
            let target = BackendID(connection.id)
            retargetWindow(target)
            // The pairing dialed the new backend over THIS window's live
            // session connection. The retarget replaces this window's
            // coordinator, so a window still sharing the old backend's
            // session must re-dial it, or it keeps showing the newly paired
            // daemon's data over the hijacked socket.
            if let bound = backendID, bound != target {
                if let repairSharedConnection {
                    repairSharedConnection()
                } else {
                    redialWindowBackend()
                }
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
        guard !lifecycleState.hasReturnedToSavedMachines, windowConnectionID == connectionId else { return }
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
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        connectionLossPresentation.becameActive { [weak self] in
            self?.reconcileBackgroundRecovery()
        }
        dependencies.backgroundTaskManager.endIfNeeded()
        refreshSyncedBackends()
    }

    /// Called when the scene leaves the foreground so agent-completion events
    /// can continue arriving during iOS's extended background execution window.
    func onScenePhaseNotActive() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        dependencies.backgroundTaskManager.beginIfNeeded()
    }

    /// Inactive alone (Control Center, permissions, etc.) is not a background
    /// return and must not delay an ordinary foreground connection failure.
    func onScenePhaseBackground() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        connectionLossPresentation.enteredBackground(
            // A loss already on screen (blocking or banner) stays put.
            eligible: lifecycleState.hasEnteredRemoteUI && !showsConnectionLossOverlay && !showsReadOnlyBanner
        )
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
        defer { refreshSavedConnectionsPresentation() }
        refreshInvitedConnections()
        dependencies.persistence.publishPendingBackends()
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

    func refreshSavedConnectionsPresentation() {
        guard let records = dependencies.persistence.loadConnectionsWithOutcome().connections else { return }
        savedConnections = records.sorted { lhs, rhs in
            if lhs.id == windowConnectionID { return rhs.id != windowConnectionID }
            if rhs.id == windowConnectionID { return false }
            return (lhs.lastConnectedAt ?? .distantPast) > (rhs.lastConnectedAt ?? .distantPast)
        }
        refreshInvitedReconnectCredentials(savedConnections)
        if case .pairing = currentScreen { pairingShowsSavedConnections = !savedConnections.isEmpty }
    }

    func refreshInvitedConnections(authenticate: PersistenceManager.InvitedAuthenticator? = nil) {
        let persistence = dependencies.persistence
        guard persistence.invitedRegistry != nil, invitedRefreshTask == nil else { return }
        invitedRefreshTask = Task { [weak self] in
            let outcome = await persistence.refreshInvitedSessions(authenticate: authenticate ?? { candidate in
                let connection = ConnectionManager(persistence: persistence)
                defer { connection.disconnect() }
                try await connection.connect(
                    hosts: candidate.server.hosts,
                    port: candidate.server.port,
                    token: candidate.token,
                    certFingerprint: candidate.server.certFingerprint,
                    tcAddress: candidate.server.tcAddress
                )
                return try await connection.confirmedPrincipal()
            })
            guard let self else { return }
            invitedRefreshTask = nil
            applyInvitedImportOutcome(outcome)
        }
    }

    func applyInvitedImportOutcome(_ outcome: InvitedImportOutcome) {
        let registry = dependencies.sessionRegistry
        registry.markBackendsRemoved(outcome.removedIds.map(BackendID.init))
        registry.clearRemovedMarks(outcome.addedIds.map(BackendID.init))
        for id in outcome.removedIds {
            registry.session(for: BackendID(id))?.connection.disconnect()
            dependencies.persistence.clearLastScreen(for: id)
        }
        refreshSavedConnectionsPresentation()
        if let windowID = windowConnectionID, outcome.removedIds.contains(windowID) { exitRemovedBackend() }
    }

    private func refreshInvitedReconnectCredentials(_ records: [StoredConnection]) {
        for record in records where record.invitedPersonKey != nil {
            guard !dependencies.sessionRegistry.isBackendRemoved(BackendID(record.id)) else { continue }
            let target = dependencies.sessionRegistry.session(for: BackendID(record.id))?.connection
                ?? (record.id == windowConnectionID ? dependencies.connection : nil)
            guard let target, let saved = record.principal else { continue }
            if let admitted = target.admission?.principal ?? target.currentPrincipal,
               !ConnectionPrincipal.samePerson(admitted.id, saved.id) { continue }
            target.updateCachedCredentials(
                hosts: record.server.hosts,
                port: record.server.port,
                token: record.token,
                certFingerprint: record.server.certFingerprint,
                tcAddress: record.server.tcAddress
            )
        }
    }

    /// Keep the existing bounded startup fallback, even during transport-owned
    /// reconnect. Routing completion alone does not establish overlay eligibility.
    func onInitialWorkspaceLoadComplete(attemptID: Int) {
        guard !lifecycleState.hasReturnedToSavedMachines, case .connecting = currentScreen,
              attemptID == connectionAttemptId else { return }
        onConnectionSuccess()
    }

    func onConnectionSuccess() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        lifecycleState.completeInitialRouting()
        defer { establishConnectionLossEligibility() }
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
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        connectingStartedByLaunch = false
        currentScreen = .connecting
    }

    func onReconnect() {
        currentScreen = .pairing
        refreshSavedConnectionsPresentation()
    }

    /// Leave this remote session without forgetting its pairing. Unlike Log
    /// Off, this never edits credentials or marks the backend removed.
    func onReturnToSavedMachines() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        stopConnectionLifecycleForReturnHome()
        connectingStartedByLaunch = false
        isDisconnected = false
        selectedWorkspaceId = nil
        pendingDeepLinkPairing = nil
        routingState.stashedDeepLinkPayload = nil
        routingState.pendingNotificationSelection = nil
        pairingShowsSavedConnections = !dependencies.persistence.loadConnections().isEmpty
        currentScreen = .pairing
        if let returnWindowToSavedMachines {
            returnWindowToSavedMachines()
        } else {
            // No window owner in standalone tests/previews. A live window
            // must use the hook so surviving windows keep their connection.
            dependencies.connection.disconnect()
            resetWorkspaceStore()
        }
    }

    /// Drop the previous daemon's workspace data so no stale rows are shown
    /// after reconnecting, and so ConnectingView's waitForWorkspaceData
    /// (which polls lastUpdated == nil) genuinely waits for the new daemon.
    private func resetWorkspaceStore() {
        dependencies.workspaceStore.workspaces = []
        dependencies.workspaceStore.lastUpdated = nil
    }

    /// Re-dial this window's own backend after its live session connection
    /// was used to pair a different one: drop the hijacked socket and the
    /// other daemon's workspace data, then restart the attempt —
    /// ConnectingView dials from windowConnection, this window's own saved
    /// record.
    func redialWindowBackend() {
        resetConnectionLossEligibility()
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
        resetConnectionLossEligibility()
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
        resetConnectionLossEligibility()
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = false
        resumeConnectionLifecycleIfNeeded()
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

    /// Log Off forgets this window's backend only. Every window on the
    /// forgotten backend leaves it via the registry's removal mark (the
    /// window root closes it, or rebinds a last remaining window to the
    /// pairing surface, offering any remaining saved connections).
    @discardableResult
    func onLogOff() -> Bool {
        // Use the window's identity, not an optional storage lookup that can
        // disappear on read failure and falsely report a successful Log Off.
        if let connectionID = windowConnectionID {
            guard dependencies.persistence.deleteConnection(id: connectionID) else {
                AppLog.app.error("[AppCoordinator] Failed to forget saved connection during log off")
                handleFailedLogOff()
                return false
            }
            dependencies.persistence.clearLastScreen(for: connectionID)
            dependencies.sessionRegistry.markBackendRemoved(BackendID(connectionID))
        }
        exitRemovedBackend()
        return true
    }

    /// A user-requested log off always disconnects, even when the saved record
    /// cannot be forgotten. Keep persistence-derived state intact and surface
    /// the failure instead of routing to first-run pairing.
    private func handleFailedLogOff() {
        resetConnectionLossEligibility()
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        selectedWorkspaceId = nil
        routeToConnectionFailure(
            error: String(localized: "Could not forget this connection. Please try again."),
            retryPolicy: .manualLogOff
        )
    }
}
