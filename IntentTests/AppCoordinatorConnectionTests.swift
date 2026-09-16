import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

extension AppCoordinatorTests {
    @Test @MainActor func currentScreenInvalidatesObservation() {
        let coordinator = AppCoordinator(persistence: persistence)
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = coordinator.currentScreen
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }

        coordinator.onConnectionSuccess()

        #expect(changeCount.withLock { $0 } == 1)
    }

    // MARK: - Per-workspace navigation state restoration

    /// Clean up all PersistenceManager state that could leak between tests
    func cleanupLastScreen() {
        persistence.clearLastScreen(for: Self.windowBackend.connectionID)
    }

    // MARK: - Connection routing

    /// Remove all connection-related state (new blob, legacy entries, active pointer).
    func resetConnectionState() {
        let persistenceManager = persistence
        persistenceManager.deleteFromKeychain(account: persistenceManager.keychainAccountConnections)
        persistenceManager.deleteFromKeychain(account: persistenceManager.keychainAccountServer)
        persistenceManager.deleteFromKeychain(account: persistenceManager.keychainAccountToken)
        persistenceManager.defaults.removeObject(forKey: persistenceManager.activeConnectionIdKey)
        persistenceManager.defaults.removeObject(forKey: persistenceManager.serverKey)
    }

    func saveWorkspaceListScreen(for connection: StoredConnection) {
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceList",
                workspaceId: nil,
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: connection.id
        )
    }

    static func makeConnection(port: Int) -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"],
                port: port,
                name: "daemon-\(port)",
                pairedAt: Date()
            ),
            token: "tok-\(port)"
        )
    }

    static func makeWorkspace(id: String) -> Workspace {
        Workspace(
            id: id,
            title: "WS \(id)",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil
        )
    }

    /// Seed WorkspaceStore.shared as if a previous daemon's list had loaded.
    @MainActor static func seedWorkspaceStore() {
        WorkspaceStore.shared.workspaces = [makeWorkspace(id: "stale-ws")]
        WorkspaceStore.shared.lastUpdated = Date()
    }

    @MainActor static func resetWorkspaceStore() {
        WorkspaceStore.shared.workspaces = []
        WorkspaceStore.shared.lastUpdated = nil
    }

    @Test @MainActor func onLoadComplete_routesToConnectingWhenWindowIsBound() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        persistence.setActiveConnection(id: stored.id)

        // Empty fake registry: onLoadComplete merges the synced registry, and
        // the default one would read the host machine's real keychain.
        let coordinator = AppCoordinator(
            backendID: BackendID(stored.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()

        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLoadComplete_routesToPairingWhenWindowIsUnbound() {
        resetConnectionState()
        defer { resetConnectionState() }

        // An unbound (pairing-session) window never auto-connects, even with
        // a saved connection available.
        persistence.upsertConnection(Self.makeConnection(port: 4242))

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()

        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLoadComplete_boundWindowDialsWithoutLastUsedPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        // No last-used pointer: a bound window dials its own backend's saved
        // record, so it must route to .connecting, never to .pairing.
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))

        let coordinator = AppCoordinator(
            backendID: BackendID(stored.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()

        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLogOff_forgetsWindowBackendOnly_flagsSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: active.id)

        let coordinator = AppCoordinator(backendID: BackendID(active.id), persistence: persistence)
        coordinator.onLogOff()

        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(
            coordinator.pairingShowsSavedConnections,
            "Pairing surface should offer the remaining saved connections"
        )
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLogOff_lastConnection_behavesLikeFirstRun() {
        resetConnectionState()
        defer { resetConnectionState() }

        let only = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: only.id)

        let coordinator = AppCoordinator(backendID: BackendID(only.id), persistence: persistence)
        coordinator.onLogOff()

        #expect(persistence.loadConnections().isEmpty)
        #expect(!coordinator.pairingShowsSavedConnections)
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func failedDeleteKeepsSavedStateAndLiveWindow() {
        resetConnectionState()
        defer { resetConnectionState() }
        let storage = InMemoryKeychainStorage()
        persistence.keychainStorage = storage
        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceList",
                workspaceId: nil,
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: stored.id
        )
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore.shared,
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence,
            sessionRegistry: registry
        )
        coordinator.currentScreen = .settings

        #expect(!coordinator.onDeleteConnection(id: stored.id))

        #expect(persistence.loadConnections() == [stored])
        #expect(persistence.activeConnection()?.id == stored.id)
        #expect(persistence.loadLastScreen(for: stored.id) != nil)
        #expect(!registry.isBackendRemoved(BackendID(stored.id)))
        #expect(fake.disconnectCallCount == 0)
        if case .settings = coordinator.currentScreen {} else {
            Issue.record("Failed deletion changed the current screen")
        }
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func failedLogOffDisconnectsButKeepsSavedStateAndShowsFailure() {
        resetConnectionState()
        defer { resetConnectionState() }
        let storage = InMemoryKeychainStorage()
        persistence.keychainStorage = storage
        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceList",
                workspaceId: nil,
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: stored.id
        )
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore.shared,
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence,
            sessionRegistry: registry
        )

        #expect(!coordinator.onLogOff())

        #expect(persistence.loadConnections() == [stored])
        #expect(persistence.activeConnection()?.id == stored.id)
        #expect(persistence.loadLastScreen(for: stored.id) != nil)
        #expect(!registry.isBackendRemoved(BackendID(stored.id)))
        #expect(fake.disconnectCallCount == 1)
        if case let .connectionFailed(message) = coordinator.currentScreen {
            #expect(message == "Could not forget this connection. Please try again.")
        } else {
            Issue.record("Expected persistence failure screen")
        }
    }

    // MARK: - Window-scoped Settings / Log Off (spec lifecycle decision 2a)

    @Test @MainActor func windowConnection_showsBoundBackendNotLastUsed() {
        resetConnectionState()
        defer { resetConnectionState() }

        let bound = persistence.upsertConnection(Self.makeConnection(port: 1))
        let lastUsed = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: lastUsed.id)

        // Settings' "Connected To" section renders windowConnection: a bound
        // window must show its own backend, never the last-used pointer.
        let coordinator = AppCoordinator(
            backendID: BackendID(bound.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        #expect(coordinator.windowConnection?.id == bound.id)

        let pairingWindow = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        #expect(
            pairingWindow.windowConnection == nil,
            "An unbound (pairing) window shows no connection record"
        )
    }

    @Test @MainActor func onLogOff_boundWindow_forgetsOwnBackendOnly() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: other.id)
        saveWorkspaceListScreen(for: doomed)
        saveWorkspaceListScreen(for: other)

        let registry = BackendSessionRegistry()
        let coordinator = AppCoordinator(
            backendID: BackendID(doomed.id),
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLogOff()

        #expect(
            persistence.loadConnections().map(\.id) == [other.id],
            "Log Off must forget only this window's backend"
        )
        #expect(
            persistence.activeConnection()?.id == other.id,
            "Another backend's last-used pointer must survive"
        )
        #expect(registry.isBackendRemoved(BackendID(doomed.id)))
        #expect(!registry.isBackendRemoved(BackendID(other.id)))
        #expect(
            persistence.loadLastScreen(for: doomed.id) == nil,
            "The forgotten backend's saved screen must be cleared"
        )
        #expect(
            persistence.loadLastScreen(for: other.id) != nil,
            "Log Off must not clear another backend's saved screen"
        )
    }

    @Test @MainActor func onConnectionSuccess_windowWithoutRestorationClaimLandsOnList() {
        defer {
            cleanupLastScreen()
            persistence.clearWorkspaceScreen(workspaceId: "ws-other")
        }
        // Only the session's first window restores (spec decision 1b): a
        // duplicate window lands on the workspace list and never overwrites
        // the restoring window's saved navigation.
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: "ws-owned",
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: Self.windowBackend.connectionID
        )

        let coordinator = AppCoordinator(
            backendID: Self.windowBackend,
            persistence: persistence
        ) {
        } claimScreenRestoration: {
            false
        }
        coordinator.onConnectionSuccess()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList for a non-restoring window, got \(coordinator.currentScreen)")
        }

        coordinator.onSelectWorkspace("ws-other")
        #expect(
            persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.workspaceId == "ws-owned",
            "A non-restoring window must not overwrite the saved screen"
        )
    }

    @Test @MainActor func onPaired_resetsPairingShowsSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }
        // Without a retarget hook, pairing from the pairing surface connects
        // in place and must stop offering the saved-connections list.
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.currentScreen = .pairing
        coordinator.pairingShowsSavedConnections = true
        coordinator.onPaired(stored)
        #expect(!coordinator.pairingShowsSavedConnections)
    }

    // MARK: - Removed backend window close fallback (spec decision 2)

    // Removal-mark routing is owned by the window root (window model v2):
    // BackendWindowRoot observes the registry's removedBackendIDs and closes
    // the window or retargets a last remaining window to the pairing surface.

    @Test func removedWindowCloseDismissesWhenOtherWindowsExist() {
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 2,
            attachedRemovedBackendWindows: 0
        ) == .dismiss)
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 3,
            attachedRemovedBackendWindows: 0
        ) == .dismiss)
    }

    @Test func removedWindowCloseRetargetsLastWindowToPairing() {
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 1,
            attachedRemovedBackendWindows: 0
        ) == .retargetToPairing)
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 0,
            attachedRemovedBackendWindows: 0
        ) == .retargetToPairing)
    }

    /// Regression: two windows on the removed backend as the app's only
    /// windows must not race both into `.dismiss` (zero windows). A sibling
    /// still attached to the removed backend is not a surviving window —
    /// the first window to decide rebinds to pairing; the later one then
    /// counts the rebound survivor and dismisses.
    @Test func removedWindowCloseExcludesSiblingsStillOnRemovedBackend() {
        #expect(
            RemovedWindowCloseAction.forWindowCounts(
                connectedWindowScenes: 2,
                attachedRemovedBackendWindows: 1
            ) == .retargetToPairing,
            "First of two removed-backend windows to decide must become the pairing survivor"
        )
        #expect(
            RemovedWindowCloseAction.forWindowCounts(
                connectedWindowScenes: 2,
                attachedRemovedBackendWindows: 0
            ) == .dismiss,
            "The later window counts the rebound survivor and dismisses"
        )
        #expect(
            RemovedWindowCloseAction.forWindowCounts(
                connectedWindowScenes: 3,
                attachedRemovedBackendWindows: 1
            ) == .dismiss,
            "With a window on another backend surviving, every removed-backend window dismisses"
        )
    }

    // MARK: - Window retarget policy (window model v2)

    // WindowRetargetRoute.route decides whether a switch/pair action opens or
    // raises the target backend's own window (multi-window platforms),
    // replaces an unbound pairing window with the target's own window, or
    // rebinds the current window in place (single-window platforms).

    @Test func retargetRouteOpensTargetWindowOnMultiWindowPlatforms() {
        let current = BackendID(UUID())
        let target = BackendID(UUID())
        #expect(
            WindowRetargetRoute.route(
                currentBackendID: current,
                target: target,
                supportsMultipleWindows: true
            ) == .openTargetWindow,
            "A bound window on a multi-window platform never retargets; the target's window is opened or raised"
        )
    }
}
