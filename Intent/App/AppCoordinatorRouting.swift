import Foundation

final class AppCoordinatorRoutingState {
    struct PendingNotificationSelection {
        let agentId: String
        let workspaceId: String
        let agentName: String
        let connectionId: UUID
    }

    var hasLoadCompleted = false
    var stashedDeepLink: DeepLinkRequest.Target?
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
            connectionScreen = .pairing(showsSavedConnections: !dependencies.persistence.loadConnections().isEmpty)
            currentScreen = .pairing
        }
        if let target = routingState.stashedDeepLink {
            routingState.stashedDeepLink = nil
            pendingDeepLink = DeepLinkRequest(target: target)
        }
    }

    func onDeepLinkPaired(_ connection: StoredConnection) {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        pendingDeepLink = nil
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

    func onPaired(_ connection: StoredConnection) {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        if backendID?.connectionID == connection.id, !currentScreen.supportsConnectionLossOverlay {
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
            let route = retargetRoute?(target) ?? .rebindInPlace
            retargetWindow(target)
            if let bound = backendID, bound != target {
                if route == .openTargetWindow {
                    redialWindowBackend()
                } else if let repairSharedConnection {
                    repairSharedConnection()
                } else {
                    redialWindowBackend()
                }
            }
            return
        }
        if case .pairing = currentScreen {
            connectionScreen = .pairing(showsSavedConnections: false)
            onConnectionSuccess()
        } else {
            onSwitchConnection(id: connection.id)
        }
    }

    var windowConnectionID: UUID? {
        backendID?.connectionID
    }

    var windowConnection: StoredConnection? {
        guard let backendID else { return nil }
        return dependencies.persistence.loadConnections().first { $0.id == backendID.connectionID }
    }

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

    func onScenePhaseActive() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        connectionLossPresentation.becameActive { [weak self] in
            self?.reconcileBackgroundRecovery()
        }
        dependencies.backgroundTaskManager.endIfNeeded()
        refreshSyncedBackends()
    }

    func onScenePhaseNotActive() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        dependencies.backgroundTaskManager.beginIfNeeded()
    }

    func onScenePhaseBackground() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        connectionLossPresentation.enteredBackground(
            eligible: lifecycleState.hasEnteredRemoteUI && !showsConnectionLossOverlay && !showsReadOnlyBanner
        )
    }

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
            if case .pairing = currentScreen {
                connectionScreen = .pairing(showsSavedConnections: !dependencies.persistence.loadConnections().isEmpty)
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
        if case .pairing = currentScreen { connectionScreen = .pairing(showsSavedConnections: !savedConnections.isEmpty) }
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
        connectionScreen = .connecting(startedByLaunch: false)
        currentScreen = .connecting
    }

    func onReconnect() {
        currentScreen = .pairing
        refreshSavedConnectionsPresentation()
    }

    func onReturnToSavedMachines() {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        stopConnectionLifecycleForReturnHome()
        connectionLoss = .none
        selectedWorkspaceId = nil
        pendingDeepLink = nil
        routingState.stashedDeepLink = nil
        routingState.pendingNotificationSelection = nil
        connectionScreen = .pairing(showsSavedConnections: !dependencies.persistence.loadConnections().isEmpty)
        currentScreen = .pairing
        if let returnWindowToSavedMachines {
            returnWindowToSavedMachines()
        } else {
            dependencies.connection.disconnect()
            resetWorkspaceStore()
        }
    }

    private func resetWorkspaceStore() {
        dependencies.workspaceStore.forgetPublishedWorkspaces()
    }

    func redialWindowBackend() {
        resetConnectionLossEligibility()
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        restartConnectionAttempt()
    }

    private func exitRemovedBackend() {
        resetConnectionLossEligibility()
        dependencies.connection.disconnect()
        resetWorkspaceStore()
        if let connectionID = windowConnectionID {
            dependencies.persistence.clearLastScreen(for: connectionID)
        }
        selectedWorkspaceId = nil
        connectionScreen = .pairing(showsSavedConnections: !dependencies.persistence.loadConnections().isEmpty)
        currentScreen = .pairing
    }

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
        resumeConnectionLifecycleIfNeeded()
        restartConnectionAttempt()
    }

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
        } else if case .pairing = connectionScreen, dependencies.persistence.loadConnections().isEmpty {
            connectionScreen = .pairing(showsSavedConnections: false)
        }
        return true
    }

    @discardableResult
    func onLogOff() -> Bool {
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
