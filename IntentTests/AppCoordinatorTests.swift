import Foundation
import Observation
import Security
import Synchronization
import Testing
import UIKit
@testable import Intent

/// `AppCoordinator` takes its workspace store and connection explicitly (they
/// come from the owning `BackendSession`). Navigation-only tests keep using
/// the process-wide instances. Window model v2: a coordinator bound to a
/// `backendID` drives a backend window; an unbound one drives a transient
/// pairing window.
extension AppCoordinator {
    @MainActor
    convenience init(
        backendID: BackendID? = nil,
        persistence: PersistenceManager = PersistenceManager.shared,
        sessionRegistry: BackendSessionRegistry = .shared,
        syncedRegistry: SyncedBackendRegistry = SyncedBackendRegistry(),
        backgroundTaskManager: BackgroundTaskManager = BackgroundTaskManager(),
        reconnectLoadingObservationDidChange: @escaping @Sendable () -> Void = {},
        claimScreenRestoration: @escaping @MainActor () -> Bool = { true }
    ) {
        self.init(
            workspaceStore: WorkspaceStore.shared,
            connection: ConnectionManager.shared,
            backendID: backendID,
            persistence: persistence,
            sessionRegistry: sessionRegistry,
            syncedRegistry: syncedRegistry,
            backgroundTaskManager: backgroundTaskManager,
            reconnectLoadingObservationDidChange: reconnectLoadingObservationDidChange,
            claimScreenRestoration: claimScreenRestoration)
    }
}

@Suite(.serialized)
final class AppCoordinatorTests {

    /// Per-test isolated persistence. Swift Testing creates a fresh suite
    /// instance per test, so each test gets its own UserDefaults suite and
    /// in-memory keychain — persisted navigation state written by one test
    /// can never leak into another (intent-hq/monorepo#2677). The suite's
    /// persistent domain is removed again in deinit so runs don't accumulate
    /// UUID-named plists in the test host.
    private let persistence: PersistenceManager
    private let suiteName: String

    /// Backend identity for tests that bind the coordinator to a window
    /// backend without needing a saved connection record. Sharing it across
    /// tests is safe: each test's persistence uses its own UserDefaults suite.
    private static let windowBackend = BackendID(UUID())

    init() {
        // The coordinator under test uses the injected per-test persistence,
        // but non-injected globals (e.g. ConnectionManager.shared's route
        // refresh) can still reach PersistenceManager.shared — keep its
        // keychain in-memory so SecItem is never hit in headless CI.
        _ = TestKeychainStorage.installed
        suiteName = "AppCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults, keychainStorage: InMemoryKeychainStorage())
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Navigation transitions

    @Test @MainActor func onConnectionSuccess_setsWorkspaceList() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onConnectionSuccess()
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func notificationSelectionBeforeLoadRoutesAfterConnectionSuccess() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        persistence.setActiveConnection(id: stored.id)
        let coordinator = AppCoordinator(
            backendID: BackendID(stored.id),
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))

        coordinator.handleNotificationSelection(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent",
            connectionId: stored.id)
        coordinator.onLoadComplete()
        if case .connecting = coordinator.currentScreen {
            // Normal cold-start routing remains in control until connection succeeds.
        } else {
            Issue.record("Expected .connecting before connection success, got \(coordinator.currentScreen)")
        }

        coordinator.onConnectionSuccess()

        if case .agentConversation(let agentId, let workspaceId, let agentName) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(workspaceId == "workspace-1")
            #expect(agentName == "Build Agent")
        } else {
            Issue.record("Expected notification target conversation, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func notificationSelectionWaitsOnFailedAndDisconnectedScreens() {
        resetConnectionState()
        defer { resetConnectionState() }
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        persistence.setActiveConnection(id: stored.id)
        let coordinator = AppCoordinator(backendID: BackendID(stored.id), persistence: persistence)

        coordinator.currentScreen = .connectionFailed(error: "timeout")
        coordinator.handleNotificationSelection(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent",
            connectionId: stored.id)
        if case .connectionFailed = coordinator.currentScreen {} else {
            Issue.record("Notification replaced the connection failure screen")
        }
        coordinator.onRetryConnection()
        coordinator.onConnectionSuccess()
        if case .agentConversation(let agentId, _, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
        } else {
            Issue.record("Expected deferred notification after retry")
        }

        coordinator.currentScreen = .disconnected
        coordinator.handleNotificationSelection(
            agentId: "agent-2", workspaceId: "workspace-2", agentName: "Test Agent",
            connectionId: stored.id)
        if case .disconnected = coordinator.currentScreen {} else {
            Issue.record("Notification replaced the disconnected screen")
        }
        coordinator.onRetryConnection()
        coordinator.onConnectionSuccess()
        if case .agentConversation(let agentId, _, _) = coordinator.currentScreen {
            #expect(agentId == "agent-2")
        } else {
            Issue.record("Expected deferred notification after reconnect")
        }
    }

    @Test @MainActor func notificationSelectionForOtherBackendIsDropped() {
        resetConnectionState()
        defer { resetConnectionState() }
        let first = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let second = persistence.upsertConnection(Self.makeConnection(port: 5252))
        // Window model v2: a tap for a backend this window doesn't show is
        // dropped — the multi-window tap route opens that backend's window.
        let coordinator = AppCoordinator(backendID: BackendID(first.id), persistence: persistence)
        coordinator.currentScreen = .connecting
        coordinator.handleNotificationSelection(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent",
            connectionId: second.id)

        coordinator.onConnectionSuccess()

        if case .workspaceList = coordinator.currentScreen {} else {
            Issue.record("A notification for another backend must not route in this window")
        }
    }

    @Test @MainActor func onConnectionFailed_setsConnectionFailed() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onConnectionFailed(error: "timeout")
        if case .connectionFailed(let error) = coordinator.currentScreen {
            #expect(error == "timeout")
        } else {
            Issue.record("Expected .connectionFailed, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onRetryConnection_setsConnecting() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onRetryConnection()
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onPaired_retargetsWindowToPairedBackend() {
        resetConnectionState()
        defer { resetConnectionState() }
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let coordinator = AppCoordinator(persistence: persistence)
        var retargeted: [BackendID] = []
        coordinator.retargetWindow = { retargeted.append($0) }
        coordinator.onPaired(stored)
        #expect(retargeted == [BackendID(stored.id)],
                "A pairing must route to the paired backend's window")
    }

    /// Regression (window model v2): pairing a different backend from a
    /// BOUND window dials the new daemon over this window's live session
    /// connection. After the retarget hook routes to the target's own
    /// window, this window must drop the hijacked socket and the other
    /// daemon's data and re-dial its own backend — not keep showing the
    /// newly paired daemon's workspaces.
    @Test @MainActor func onPaired_boundWindow_redialsOwnBackendAfterRoutingOut() {
        let own = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let paired = persistence.upsertConnection(Self.makeConnection(port: 5252))
        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces(
            [Self.makeWorkspace(id: "ws-paired-daemon", attention: "none")])
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: store, connection: fake,
            backendID: BackendID(own.id), persistence: persistence)
        coordinator.currentScreen = .workspaceList
        var retargeted: [BackendID] = []
        coordinator.retargetWindow = { retargeted.append($0) }

        coordinator.onPaired(paired)

        #expect(retargeted == [BackendID(paired.id)],
                "The pairing must still route to the paired backend's window")
        #expect(fake.disconnectCallCount == 1,
                "The hijacked socket must be dropped")
        #expect(store.workspaces.isEmpty,
                "The paired daemon's workspace data must be dropped")
        if case .connecting = coordinator.currentScreen {} else {
            Issue.record("Expected a re-dial of this window's own backend, got \(coordinator.currentScreen)")
        }
    }

    /// A re-pair routed for this window's own backend must not trigger the
    /// repair re-dial (no disconnect, screen untouched).
    @Test @MainActor func onPaired_boundWindow_sameBackend_noRedial() {
        let own = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake,
            backendID: BackendID(own.id), persistence: persistence)
        coordinator.currentScreen = .workspaceList
        var retargeted: [BackendID] = []
        coordinator.retargetWindow = { retargeted.append($0) }

        coordinator.onPaired(own)

        #expect(retargeted == [BackendID(own.id)])
        #expect(fake.disconnectCallCount == 0,
                "A same-backend pairing must not drop this window's connection")
        if case .workspaceList = coordinator.currentScreen {} else {
            Issue.record("Expected screen untouched, got \(coordinator.currentScreen)")
        }
    }

    /// An unbound (pairing) window routes the pairing via the retarget hook
    /// with no repair — the hook rebinds it in place (single-window) or
    /// replaces it with the target's own window (multi-window).
    @Test @MainActor func onPaired_unboundWindow_retargetsWithoutRedial() {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake,
            persistence: persistence)
        coordinator.currentScreen = .pairing
        var retargeted: [BackendID] = []
        coordinator.retargetWindow = { retargeted.append($0) }

        coordinator.onPaired(stored)

        #expect(retargeted == [BackendID(stored.id)])
        #expect(fake.disconnectCallCount == 0)
        if case .pairing = coordinator.currentScreen {} else {
            Issue.record("Expected screen untouched, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onOpenSettings_setsSettings() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onOpenSettings()
        if case .settings = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .settings, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLogOff_setsPairing() {
        resetConnectionState()
        defer { resetConnectionState() }
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onLogOff()
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSettingsBack_setsWorkspaceList() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSettingsBack()
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onReconnect_setsPairing() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onReconnect()
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func initialScreen_isLoading() {
        let coordinator = AppCoordinator(persistence: persistence)
        if case .loading = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected initial screen to be .loading, got \(coordinator.currentScreen)")
        }
    }

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
    private func cleanupLastScreen() {
        persistence.clearLastScreen(for: Self.windowBackend.connectionID)
    }

    // MARK: - Connection routing

    /// Remove all connection-related state (new blob, legacy entries, active pointer).
    private func resetConnectionState() {
        let pm = persistence
        pm.deleteFromKeychain(account: pm.keychainAccountConnections)
        pm.deleteFromKeychain(account: pm.keychainAccountServer)
        pm.deleteFromKeychain(account: pm.keychainAccountToken)
        pm.defaults.removeObject(forKey: pm.activeConnectionIdKey)
        pm.defaults.removeObject(forKey: pm.serverKey)
    }

    private static func makeConnection(port: Int) -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"], port: port, name: "daemon-\(port)", pairedAt: Date()),
            token: "tok-\(port)")
    }

    private static func makeWorkspace(id: String) -> Workspace {
        Workspace(
            id: id, title: "WS \(id)", branch: nil, baseRef: nil, status: nil,
            activity: nil, displayStatus: nil, lastActivity: nil, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil, prNumber: nil,
            diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil,
            taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
    }

    /// Seed WorkspaceStore.shared as if a previous daemon's list had loaded.
    @MainActor private static func seedWorkspaceStore() {
        WorkspaceStore.shared.workspaces = [makeWorkspace(id: "stale-ws")]
        WorkspaceStore.shared.lastUpdated = Date()
    }

    @MainActor private static func resetWorkspaceStore() {
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
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
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
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
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
            syncedRegistry: Self.syncedRegistry(payloads: []))
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
        #expect(coordinator.pairingShowsSavedConnections,
                "Pairing surface should offer the remaining saved connections")
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
        persistence.saveLastScreen(PersistenceManager.SavedScreen(
            screen: "workspaceList", workspaceId: nil, agentId: nil,
            agentName: nil, noteId: nil, noteTitle: nil), for: stored.id)
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore.shared, connection: fake,
            backendID: BackendID(stored.id), persistence: persistence,
            sessionRegistry: registry)
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

    @Test @MainActor func failedLogOffDisconnectsButKeepsSavedStateAndShowsFailure() {
        resetConnectionState()
        defer { resetConnectionState() }
        let storage = InMemoryKeychainStorage()
        persistence.keychainStorage = storage
        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)
        persistence.saveLastScreen(PersistenceManager.SavedScreen(
            screen: "workspaceList", workspaceId: nil, agentId: nil,
            agentName: nil, noteId: nil, noteTitle: nil), for: stored.id)
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore.shared, connection: fake,
            backendID: BackendID(stored.id), persistence: persistence,
            sessionRegistry: registry)

        #expect(!coordinator.onLogOff())

        #expect(persistence.loadConnections() == [stored])
        #expect(persistence.activeConnection()?.id == stored.id)
        #expect(persistence.loadLastScreen(for: stored.id) != nil)
        #expect(!registry.isBackendRemoved(BackendID(stored.id)))
        #expect(fake.disconnectCallCount == 1)
        if case .connectionFailed(let message) = coordinator.currentScreen {
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
            syncedRegistry: Self.syncedRegistry(payloads: []))
        #expect(coordinator.windowConnection?.id == bound.id)

        let pairingWindow = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        #expect(pairingWindow.windowConnection == nil,
                "An unbound (pairing) window shows no connection record")
    }

    @Test @MainActor func onLogOff_boundWindow_forgetsOwnBackendOnly() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: other.id)
        persistence.saveLastScreen(PersistenceManager.SavedScreen(
            screen: "workspaceList", workspaceId: nil, agentId: nil,
            agentName: nil, noteId: nil, noteTitle: nil), for: doomed.id)
        persistence.saveLastScreen(PersistenceManager.SavedScreen(
            screen: "workspaceList", workspaceId: nil, agentId: nil,
            agentName: nil, noteId: nil, noteTitle: nil), for: other.id)

        let registry = BackendSessionRegistry()
        let coordinator = AppCoordinator(
            backendID: BackendID(doomed.id),
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLogOff()

        #expect(persistence.loadConnections().map(\.id) == [other.id],
                "Log Off must forget only this window's backend")
        #expect(persistence.activeConnection()?.id == other.id,
                "Another backend's last-used pointer must survive")
        #expect(registry.isBackendRemoved(BackendID(doomed.id)))
        #expect(!registry.isBackendRemoved(BackendID(other.id)))
        #expect(persistence.loadLastScreen(for: doomed.id) == nil,
                "The forgotten backend's saved screen must be cleared")
        #expect(persistence.loadLastScreen(for: other.id) != nil,
                "Log Off must not clear another backend's saved screen")
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
                screen: "workspaceDetail", workspaceId: "ws-owned",
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
            for: Self.windowBackend.connectionID)

        let coordinator = AppCoordinator(
            backendID: Self.windowBackend,
            persistence: persistence,
            claimScreenRestoration: { false })
        coordinator.onConnectionSuccess()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList for a non-restoring window, got \(coordinator.currentScreen)")
        }

        coordinator.onSelectWorkspace("ws-other")
        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.workspaceId == "ws-owned",
                "A non-restoring window must not overwrite the saved screen")
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
            connectedWindowScenes: 2, attachedRemovedBackendWindows: 0) == .dismiss)
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 3, attachedRemovedBackendWindows: 0) == .dismiss)
    }

    @Test func removedWindowCloseRetargetsLastWindowToPairing() {
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 1, attachedRemovedBackendWindows: 0) == .retargetToPairing)
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 0, attachedRemovedBackendWindows: 0) == .retargetToPairing)
    }

    /// Regression: two windows on the removed backend as the app's only
    /// windows must not race both into `.dismiss` (zero windows). A sibling
    /// still attached to the removed backend is not a surviving window —
    /// the first window to decide rebinds to pairing; the later one then
    /// counts the rebound survivor and dismisses.
    @Test func removedWindowCloseExcludesSiblingsStillOnRemovedBackend() {
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 2, attachedRemovedBackendWindows: 1) == .retargetToPairing,
            "First of two removed-backend windows to decide must become the pairing survivor")
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 2, attachedRemovedBackendWindows: 0) == .dismiss,
            "The later window counts the rebound survivor and dismisses")
        #expect(RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: 3, attachedRemovedBackendWindows: 1) == .dismiss,
            "With a window on another backend surviving, every removed-backend window dismisses")
    }

    // MARK: - Window retarget policy (window model v2)

    // WindowRetargetRoute.route decides whether a switch/pair action opens or
    // raises the target backend's own window (multi-window platforms),
    // replaces an unbound pairing window with the target's own window, or
    // rebinds the current window in place (single-window platforms).

    @Test func retargetRouteOpensTargetWindowOnMultiWindowPlatforms() {
        let current = BackendID(UUID())
        let target = BackendID(UUID())
        #expect(WindowRetargetRoute.route(
            currentBackendID: current, target: target,
            supportsMultipleWindows: true) == .openTargetWindow,
            "A bound window on a multi-window platform never retargets; the target's window is opened or raised")
    }

    @Test func retargetRouteRebindsInPlaceWhenTargetIsCurrentBackend() {
        let current = BackendID(UUID())
        #expect(WindowRetargetRoute.route(
            currentBackendID: current, target: current,
            supportsMultipleWindows: true) == .rebindInPlace,
            "Switching to the backend the window is already bound to stays in place")
    }

    @Test func retargetRouteReplacesUnboundPairingWindow() {
        #expect(WindowRetargetRoute.route(
            currentBackendID: nil, target: BackendID(UUID()),
            supportsMultipleWindows: true) == .replaceWindow,
            "An unbound (pairing) window on a multi-window platform is replaced by the target's own window so the scene value is set at creation and stays raisable by openWindow(value:)")
    }

    @Test func retargetRouteRebindsInPlaceOnSingleWindowPlatforms() {
        let current = BackendID(UUID())
        let target = BackendID(UUID())
        #expect(WindowRetargetRoute.route(
            currentBackendID: current, target: target,
            supportsMultipleWindows: false) == .rebindInPlace,
            "iPhone (single-window) always rebinds the one window in place")
        #expect(WindowRetargetRoute.route(
            currentBackendID: nil, target: target,
            supportsMultipleWindows: false) == .rebindInPlace)
    }

    // MARK: - Deep-link URL classification (intent://)

    @Test func incomingDeepLink_classifiesPairURL() {
        let link = IncomingDeepLink.classify(
            URL(string: "intent://pair?token=t&host=127.0.0.1&port=5181")!)
        #expect(link == .pair(PairingPayload(
            hosts: ["127.0.0.1"], port: 5181, token: "t",
            certFingerprint: nil, tcAddress: nil)))
    }

    @Test func incomingDeepLink_classifiesInviteURLByHostOnly() {
        // The daemon's envelope (pair minus token, plus inviteId/secret).
        #expect(IncomingDeepLink.classify(URL(string:
            "intent://invite?v=1&host=10.0.0.5&port=7443&fp=AB:CD&inviteId=inv-1&secret=s3cret")!)
            == .invite)
        // The host alone decides: iOS never parses the invite payload.
        #expect(IncomingDeepLink.classify(URL(string: "intent://invite")!) == .invite)
        #expect(IncomingDeepLink.classify(URL(string: "intent://invite?token=t&host=h&port=1")!)
            == .invite)
    }

    @Test func incomingDeepLink_classifiesOtherURLsAsUnhandled() {
        #expect(IncomingDeepLink.classify(URL(string: "intent://something?x=1")!) == .unhandled)
        // Missing token — PairingPayload.parse rejects it.
        #expect(IncomingDeepLink.classify(URL(string: "intent://pair?host=127.0.0.1&port=5181")!)
            == .unhandled)
        // Wrong scheme, even with the invite host.
        #expect(IncomingDeepLink.classify(URL(string: "https://invite?inviteId=inv-1")!)
            == .unhandled)
    }

    // MARK: - Deep-link URL routing (intent://)

    @Test @MainActor func handleIncomingURL_inviteURL_presentsNoticeAndPairsNothing() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLoadComplete()

        coordinator.handleIncomingURL(URL(string:
            "intent://invite?v=1&host=10.0.0.5&port=7443&fp=AB:CD&inviteId=inv-1&secret=s3cret")!)

        #expect(coordinator.isInviteNoticePresented)
        #expect(coordinator.pendingDeepLinkPairing == nil)
        #expect(persistence.loadConnections().isEmpty)
        if case .pairing = coordinator.currentScreen {
            // pass — app state untouched
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleIncomingURL_inviteURL_beforeLoadComplete_stashesUntilLoad() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))

        // Cold start: the URL arrives while currentScreen is still .loading.
        // Two invites before load coalesce into a single notice.
        coordinator.handleIncomingURL(URL(string: "intent://invite?inviteId=inv-1&secret=s")!)
        coordinator.handleIncomingURL(URL(string: "intent://invite?inviteId=inv-2&secret=s")!)
        #expect(!coordinator.isInviteNoticePresented)

        coordinator.onLoadComplete()
        #expect(coordinator.isInviteNoticePresented)
        #expect(coordinator.pendingDeepLinkPairing == nil)
        if case .pairing = coordinator.currentScreen {
            // pass — load still routed to its normal first screen
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }

        // The stash is consumed once: after the user dismisses the alert a
        // later load completion must not replay the notice.
        coordinator.isInviteNoticePresented = false
        coordinator.onLoadComplete()
        #expect(!coordinator.isInviteNoticePresented,
            "A stashed invite notice must not replay after dismissal")
    }

    @Test @MainActor func handleIncomingURL_pairURL_presentsConfirmation() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLoadComplete()

        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=127.0.0.1&port=5181")!)

        #expect(coordinator.pendingDeepLinkPairing?.payload == PairingPayload(
            hosts: ["127.0.0.1"], port: 5181, token: "t",
            certFingerprint: nil, tcAddress: nil))
    }

    @Test @MainActor func handleIncomingURL_nonPairURL_isIgnored() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLoadComplete()

        coordinator.handleIncomingURL(URL(string: "intent://something?x=1")!)

        #expect(coordinator.pendingDeepLinkPairing == nil)
        #expect(!coordinator.isInviteNoticePresented, "Only the invite host surfaces the notice")
        if case .pairing = coordinator.currentScreen {
            // pass — app state untouched
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleIncomingURL_malformedPairURL_isIgnored() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLoadComplete()

        // Missing token — PairingPayload.parse rejects it.
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?host=127.0.0.1&port=5181")!)

        #expect(coordinator.pendingDeepLinkPairing == nil)
        if case .pairing = coordinator.currentScreen {
            // pass — app state untouched
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleIncomingURL_beforeLoadComplete_stashesUntilLoad() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))

        // Cold start: the URL arrives while currentScreen is still .loading.
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=10.0.0.5&port=4242")!)
        #expect(coordinator.pendingDeepLinkPairing == nil)

        coordinator.onLoadComplete()
        #expect(coordinator.pendingDeepLinkPairing?.payload.hosts == ["10.0.0.5"])
        if case .pairing = coordinator.currentScreen {
            // pass — load still routed to its normal first screen
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeepLinkPaired_fromPairingSurface_landsInConnectedUI() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLoadComplete()
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=127.0.0.1&port=5181")!)

        coordinator.onDeepLinkPaired(Self.makeConnection(port: 5181))

        #expect(coordinator.pendingDeepLinkPairing == nil)
        if case .workspaceList = coordinator.currentScreen {
            // pass — same landing as a successful QR scan
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeepLinkPaired_whileConnectedElsewhere_switchesConnection() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.currentScreen = .workspaceList
        coordinator.pendingDeepLinkPairing = DeepLinkPairingRequest(
            payload: PairingPayload(
                hosts: ["10.0.0.1"], port: 4242, token: "tok-4242",
                certFingerprint: nil, tcAddress: nil))

        coordinator.onDeepLinkPaired(stored)

        #expect(coordinator.pendingDeepLinkPairing == nil)
        #expect(persistence.activeConnection()?.id == stored.id)
        if case .connecting = coordinator.currentScreen {
            // pass — routed through onSwitchConnection
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeepLinkPaired_whileConnecting_restartsConnectionAttempt() {
        resetConnectionState()
        defer { resetConnectionState() }

        // Cold start of a bound window: onLoadComplete routes to .connecting
        // and the stashed deep link is confirmed over it.
        let old = persistence.upsertConnection(Self.makeConnection(port: 1111))
        persistence.setActiveConnection(id: old.id)
        let coordinator = AppCoordinator(
            backendID: BackendID(old.id),
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=10.0.0.2&port=2222")!)
        coordinator.onLoadComplete()
        if case .connecting = coordinator.currentScreen {
            // as expected — the deep-link sheet is presented over .connecting
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
        let attemptBefore = coordinator.connectionAttemptId

        let paired = persistence.upsertConnection(Self.makeConnection(port: 2222))
        coordinator.onDeepLinkPaired(paired)

        // Screen stays .connecting (same value), so the restart must come
        // from the attempt id that keys ConnectingView's .task(id:).
        #expect(coordinator.pendingDeepLinkPairing == nil)
        #expect(persistence.activeConnection()?.id == paired.id)
        #expect(coordinator.connectionAttemptId != attemptBefore,
                "Switching while already on .connecting must restart the attempt")
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Synced backend registry merge

    /// Registry whose keychain returns the given records as raw rows.
    private static func syncedRegistry(payloads: [String]) -> SyncedBackendRegistry {
        let rows: [[String: Any]] = payloads.enumerated().map { index, payload in
            [
                kSecAttrAccount as String: "row-\(index)",
                kSecValueData as String: Data(payload.utf8),
            ]
        }
        return SyncedBackendRegistry(
            keychain: FakeSyncedKeychain(outcome: .rows(rows)),
            accessGroup: "T.dev.intentapp.backends")
    }

    private static let syncedLivePayload = #"{"v": 1, "label": "Synced Mac", "#
        + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
        + #""token": "tok-sync", "updatedAt": 100}"#

    @Test @MainActor func onLoadComplete_mergesRegistryAndOffersSyncedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload]))
        coordinator.onLoadComplete()

        let loaded = persistence.loadConnections()
        #expect(loaded.map(\.token) == ["tok-sync"])
        #expect(coordinator.pairingShowsSavedConnections,
                "A merged synced connection must be offered on the pairing surface")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onScenePhaseActive_mergesRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload]))
        coordinator.onScenePhaseActive()

        #expect(persistence.loadConnections().count == 1)
    }

    @Test @MainActor func scenePhaseLifecycleBeginsAndEndsBackgroundTask() {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 1)
        var beginCount = 0
        var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
        let backgroundTaskManager = BackgroundTaskManager(
            beginTask: { _ in
                beginCount += 1
                return identifier
            },
            endTask: { endedIdentifiers.append($0) }
        )
        let coordinator = AppCoordinator(
            persistence: persistence,
            backgroundTaskManager: backgroundTaskManager
        )

        coordinator.onScenePhaseNotActive()
        coordinator.onScenePhaseActive()

        #expect(beginCount == 1)
        #expect(endedIdentifiers == [identifier])
    }

    @Test @MainActor func refreshSyncedBackends_onPairingScreen_offersFreshlyMergedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        // First-run pairing screen, empty registry: nothing offered.
        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload]))
        coordinator.currentScreen = .pairing
        #expect(!coordinator.pairingShowsSavedConnections)

        // A foreground merge that adds a synced connection while the pairing
        // surface is up must start offering it.
        coordinator.onScenePhaseActive()
        #expect(coordinator.pairingShowsSavedConnections,
                "A merged synced connection must be offered on the already-visible pairing surface")
    }

    @Test @MainActor func refreshSyncedBackends_unavailableRegistryIsANoOp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let registry = SyncedBackendRegistry(
            keychain: FakeSyncedKeychain(outcome: .failure(errSecNotAvailable)),
            accessGroup: "T.dev.intentapp.backends")
        let coordinator = AppCoordinator(persistence: persistence, syncedRegistry: registry)

        #expect(coordinator.refreshSyncedBackends() == nil)
        #expect(persistence.loadConnections().map(\.id) == [stored.id])
    }

    @Test @MainActor func refreshSyncedBackends_tombstoneOnWindowBackendRoutesToPairing() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok"))
        let other = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: doomed.id)

        // Registry reads use the wall clock, so the tombstone must be recent
        // enough to be within the 30-day TTL and newer than the local pairing.
        let clock = Date().timeIntervalSince1970 * 1000
        let tombstone = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
            + #""updatedAt": \#(clock), "deleted": true}"#
        let coordinator = AppCoordinator(
            backendID: BackendID(doomed.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [tombstone]))
        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.removedActiveConnection == true)
        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(coordinator.pairingShowsSavedConnections,
                "The remaining saved connection must be offered on the pairing surface")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func refreshSyncedBackends_tombstoneKeepsOtherBackendsLastUsedPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok"))
        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: active.id)

        let clock = Date().timeIntervalSince1970 * 1000
        let tombstone = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
            + #""updatedAt": \#(clock), "deleted": true}"#
        let registry = BackendSessionRegistry()
        let coordinator = AppCoordinator(
            backendID: BackendID(doomed.id),
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [tombstone]))
        let outcome = coordinator.refreshSyncedBackends()

        // The tombstone removed this window's backend — not the last-used
        // one — so this window must still route out.
        #expect(outcome?.removedIds == [doomed.id])
        #expect(outcome?.removedActiveConnection == false)
        #expect(persistence.activeConnection()?.id == active.id)
        #expect(registry.isBackendRemoved(BackendID(doomed.id)))
        if case .pairing = coordinator.currentScreen {
            // pass — exitRemovedBackend ran for the pinned backend's removal
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func refreshSyncedBackends_activeUpdateAdoptsCredentialsIntoConnectionManager() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok-old", syncUpdatedAt: 100))
        persistence.setActiveConnection(id: active.id)

        let rotated = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.10", "port": 5252, "fingerprint": "aa:bb", "#
            + #""token": "tok-rotated", "updatedAt": 200}"#
        let coordinator = AppCoordinator(
            backendID: BackendID(active.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [rotated]))
        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.updatedIds == [active.id])
        let manager = ConnectionManager.shared
        #expect(manager.token == "tok-rotated")
        #expect(manager.port == 5252)
        #expect(manager.hosts.first == "10.9.9.10")
        #expect(manager.certFingerprint == "aa:bb")
    }

    @Test @MainActor func onReconnect_flagsSavedConnections_whenConnectionsExist() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onReconnect()

        #expect(coordinator.pairingShowsSavedConnections,
                "Pairing surface should offer saved connections after a startup connection failure")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onReconnect_noSavedConnections_behavesLikeFirstRun() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onReconnect()

        #expect(!coordinator.pairingShowsSavedConnections,
                "No saved connections must leave the pairing surface in first-run mode")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Connection-failure saved-connection alternatives

    @Test func alternativeConnections_excludesActiveConnection() {
        let active = Self.makeConnection(port: 1)
        let other = Self.makeConnection(port: 2)

        let result = ConnectionFailureView.alternativeConnections(
            connections: [active, other], activeId: active.id)

        #expect(result.map(\.id) == [other.id])
    }

    @Test func alternativeConnections_sortsMostRecentlyUsedFirst() {
        let older = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.1"], port: 1, name: "a", pairedAt: Date()),
            token: "t1", lastConnectedAt: Date(timeIntervalSinceNow: -3600))
        let newer = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.2"], port: 2, name: "b", pairedAt: Date()),
            token: "t2", lastConnectedAt: Date())
        let never = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.3"], port: 3, name: "c", pairedAt: Date()),
            token: "t3")

        let result = ConnectionFailureView.alternativeConnections(
            connections: [never, older, newer], activeId: nil)

        #expect(result.map(\.id) == [newer.id, older.id, never.id])
    }

    @Test @MainActor func onSwitchConnection_activatesTargetAndRoutesToConnecting() {
        resetConnectionState()
        defer {
            resetConnectionState()
            cleanupLastScreen()
        }

        let a = persistence.upsertConnection(Self.makeConnection(port: 1))
        let b = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: a.id)
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: "ws-1",
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
            for: b.id)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace("ws-1")
        coordinator.onSwitchConnection(id: b.id)

        #expect(persistence.activeConnection()?.id == b.id)
        #expect(persistence.loadLastScreen(for: b.id) == nil,
                "The target backend's last-screen state must be cleared on switch")
        #expect(coordinator.selectedWorkspaceId == nil,
                "selectedWorkspaceId must be reset on switch")
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSwitchConnection_resetsWorkspaceStore() {
        resetConnectionState()
        defer {
            resetConnectionState()
            Self.resetWorkspaceStore()
        }

        let target = persistence.upsertConnection(Self.makeConnection(port: 2))
        Self.seedWorkspaceStore()

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSwitchConnection(id: target.id)

        #expect(WorkspaceStore.shared.workspaces.isEmpty,
                "Previous daemon's workspaces must be dropped on switch")
        #expect(WorkspaceStore.shared.lastUpdated == nil,
                "lastUpdated must be reset so ConnectingView waits for the new daemon's data")
    }

    @Test @MainActor func onLogOff_resetsWorkspaceStore() {
        resetConnectionState()
        defer {
            resetConnectionState()
            Self.resetWorkspaceStore()
        }

        Self.seedWorkspaceStore()

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onLogOff()

        #expect(WorkspaceStore.shared.workspaces.isEmpty)
        #expect(WorkspaceStore.shared.lastUpdated == nil)
    }

    @Test @MainActor func onDeleteConnection_active_resetsWorkspaceStore() {
        resetConnectionState()
        defer {
            resetConnectionState()
            Self.resetWorkspaceStore()
        }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: active.id)
        Self.seedWorkspaceStore()

        let coordinator = AppCoordinator(backendID: BackendID(active.id), persistence: persistence)
        coordinator.onDeleteConnection(id: active.id)

        #expect(WorkspaceStore.shared.workspaces.isEmpty)
        #expect(WorkspaceStore.shared.lastUpdated == nil)
    }

    @Test @MainActor func onSwitchConnection_resetsPairingShowsSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let target = persistence.upsertConnection(Self.makeConnection(port: 1))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onSwitchConnection(id: target.id)

        #expect(!coordinator.pairingShowsSavedConnections)
    }

    @Test @MainActor func onDeleteConnection_nonActive_keepsScreenAndActiveConnection() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: active.id)

        let coordinator = AppCoordinator(backendID: BackendID(active.id), persistence: persistence)
        coordinator.onConnectionSuccess()
        coordinator.onDeleteConnection(id: other.id)

        #expect(persistence.loadConnections().map(\.id) == [active.id])
        #expect(persistence.activeConnection()?.id == active.id)
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList to be untouched, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeleteConnection_active_routesLikeLogOff_flagsSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: active.id)

        let coordinator = AppCoordinator(backendID: BackendID(active.id), persistence: persistence)
        coordinator.onDeleteConnection(id: active.id)

        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(coordinator.pairingShowsSavedConnections,
                "Pairing surface should offer the remaining saved connections")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeleteConnection_lastActive_behavesLikeFirstRun() {
        resetConnectionState()
        defer { resetConnectionState() }

        let only = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: only.id)

        let coordinator = AppCoordinator(backendID: BackendID(only.id), persistence: persistence)
        coordinator.onDeleteConnection(id: only.id)

        #expect(persistence.loadConnections().isEmpty)
        #expect(!coordinator.pairingShowsSavedConnections)
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeleteConnection_lastNonActive_clearsSavedConnectionsFlag() {
        resetConnectionState()
        defer { resetConnectionState() }

        // Post-Log Off state: no active pointer, one saved connection remaining.
        let remaining = persistence.upsertConnection(Self.makeConnection(port: 1))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onDeleteConnection(id: remaining.id)

        #expect(persistence.loadConnections().isEmpty)
        #expect(!coordinator.pairingShowsSavedConnections,
                "Flag must clear once no saved connections remain")
    }

    // MARK: - Backend removal marks pinned windows for auto-close (spec decision 2)

    /// Registry whose session factory must never run: these tests only assert
    /// removal marks, which never create or tear down sessions.
    @MainActor private static func markOnlySessionRegistry() -> BackendSessionRegistry {
        BackendSessionRegistry { kind in
            fatalError("Removal marks must not build sessions (got \(kind))")
        }
    }

    @Test @MainActor func onDeleteConnection_marksBackendRemovedInSessionRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(Self.makeConnection(port: 1))
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            persistence: persistence, sessionRegistry: registry)

        coordinator.onDeleteConnection(id: doomed.id)

        #expect(registry.isBackendRemoved(BackendID(doomed.id)),
                "Deleting a saved connection must auto-close its pinned windows")
    }

    @Test @MainActor func onLogOff_marksActiveBackendRemovedInSessionRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: active.id)
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            backendID: BackendID(active.id),
            persistence: persistence, sessionRegistry: registry)

        coordinator.onLogOff()

        #expect(registry.isBackendRemoved(BackendID(active.id)),
                "Log Off forgets the active connection; its pinned windows must close")
    }

    @Test @MainActor func refreshSyncedBackends_tombstoneMarksBackendRemovedInSessionRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok"))

        let clock = Date().timeIntervalSince1970 * 1000
        let tombstone = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
            + #""updatedAt": \#(clock), "deleted": true}"#
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [tombstone]))

        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.removedIds == [doomed.id])
        #expect(registry.isBackendRemoved(BackendID(doomed.id)),
                "A synced tombstone must auto-close the removed backend's pinned windows")
    }

    @Test @MainActor func refreshSyncedBackends_mergeAddNeverMarksBackendsRemoved() {
        resetConnectionState()
        defer { resetConnectionState() }

        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload]))

        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.addedIds.count == 1)
        #expect(registry.removedBackendIDs.isEmpty,
                "A merge that only adds must not mark anything removed")
    }

    @Test @MainActor func onSelectWorkspace_restoresSavedConversationScreen() {
        let wsId = "test-coord-restore-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save a per-workspace conversation screen
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-x", agentName: "Tester",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        if case .agentConversation(let agentId, let wId, let name) = coordinator.currentScreen {
            #expect(agentId == "agent-x")
            #expect(wId == wsId)
            #expect(name == "Tester")
        } else {
            Issue.record("Expected .agentConversation, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_restoresSavedNoteScreen() {
        let wsId = "test-coord-restore-note-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-abc", noteTitle: "My Note"))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        if case .noteDetail(let noteId, let wId, let title) = coordinator.currentScreen {
            #expect(noteId == "note-abc")
            #expect(wId == wsId)
            #expect(title == "My Note")
        } else {
            Issue.record("Expected .noteDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_fallsBackToDetailWhenNoSavedScreen() {
        let wsId = "test-coord-no-saved-\(UUID().uuidString)"
        defer { cleanupLastScreen() }
        // Ensure no saved screen
        persistence.clearWorkspaceScreen(workspaceId: wsId)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onBackToWorkspaceDetail_clearsSavedScreen() {
        let wsId = "test-coord-back-clears-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save a screen and select the workspace
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "a", agentName: "A",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        // Now go back to workspace detail
        coordinator.onBackToWorkspaceDetail()

        // The per-workspace screen should be cleared
        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded == nil, "Per-workspace screen should be cleared after onBackToWorkspaceDetail")
    }

    @Test @MainActor func onSelectAgent_savesPerWorkspaceScreen() {
        let wsId = "test-coord-agent-saves-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-99", workspaceId: wsId, agentName: "Worker")

        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "conversation")
        #expect(loaded?.agentId == "agent-99")
        #expect(loaded?.agentName == "Worker")
    }

    @Test @MainActor func onSelectNote_savesPerWorkspaceScreen() {
        let wsId = "test-coord-note-saves-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectNote("note-55", workspaceId: wsId, noteTitle: "Design Doc")

        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "note-55")
        #expect(loaded?.noteTitle == "Design Doc")
    }

    @Test @MainActor func onBackFromNote_clearsPerWorkspaceScreen() {
        let wsId = "test-coord-backfromnote-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        // First select the workspace so selectedWorkspaceId is set
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-1", workspaceId: wsId, noteTitle: "Note")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil)

        coordinator.onBackFromNote()

        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded == nil, "Per-workspace screen should be cleared after onBackFromNote")
    }

    // MARK: - Missing workspace handling

    @Test @MainActor func handleMissingWorkspace_navigatesToWorkspaceList() {
        let wsId = "test-coord-missing-ws-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        // Simulate being on a workspace detail screen
        coordinator.onSelectWorkspace(wsId)
        if case .workspaceDetail = coordinator.currentScreen {
            // good
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }

        // Now handle the missing workspace
        coordinator.handleMissingWorkspace(workspaceId: wsId)

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after handleMissingWorkspace, got \(coordinator.currentScreen)")
        }
        #expect(coordinator.selectedWorkspaceId == nil, "selectedWorkspaceId should be nil after handleMissingWorkspace")
    }

    @Test @MainActor func handleMissingWorkspace_clearsSavedScreenState() {
        let wsId = "test-coord-missing-clears-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save both last screen and per-workspace screen
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: wsId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
            for: Self.windowBackend.connectionID)
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-1", agentName: "Worker",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        coordinator.handleMissingWorkspace(workspaceId: wsId)

        // Both should be cleared
        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID) == nil,
                "Last screen should be cleared")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil, "Per-workspace screen should be cleared")
    }

    @Test @MainActor func handleMissingWorkspace_worksFromConversationScreen() {
        let wsId = "test-coord-missing-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-x", workspaceId: wsId, agentName: "Tester")

        if case .agentConversation = coordinator.currentScreen {
            // good
        } else {
            Issue.record("Expected .agentConversation, got \(coordinator.currentScreen)")
        }

        coordinator.handleMissingWorkspace(workspaceId: wsId)

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after handleMissingWorkspace from conversation, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - iPhone note navigation regression tests

    @Test @MainActor func testNoteNavigationFromWorkspace_staysInWorkspace() {
        let wsId = "test-coord-note-nav-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-reg-1", workspaceId: wsId, noteTitle: "Regression Note")

        if case .noteDetail(let noteId, let wId, let title) = coordinator.currentScreen {
            #expect(noteId == "note-reg-1")
            #expect(wId == wsId)
            #expect(title == "Regression Note")
        } else {
            Issue.record("Expected .noteDetail, got \(coordinator.currentScreen)")
        }
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId should remain set after note navigation")
    }

    @Test @MainActor func testBackFromNote_goesToWorkspaceDetail_notWorkspaceList() {
        let wsId = "test-coord-back-note-detail-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-reg-2", workspaceId: wsId, noteTitle: "Back Test Note")
        coordinator.onBackFromNote()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId, "Should return to the same workspace")
        } else {
            Issue.record("Expected .workspaceDetail after onBackFromNote, got \(coordinator.currentScreen)")
        }
        // Ensure we did NOT end up at workspaceList
        if case .workspaceList = coordinator.currentScreen {
            Issue.record("onBackFromNote should go to .workspaceDetail, NOT .workspaceList")
        }
    }

    @Test @MainActor func testNoteNavigationPreservesWorkspaceId() {
        let wsId = "test-coord-preserve-wsid-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId should be set after onSelectWorkspace")

        coordinator.onSelectNote("note-reg-3", workspaceId: wsId, noteTitle: "Preserve WS Note")
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId must not become nil after onSelectNote (regression: SwiftUI popped the stack)")
    }

    // MARK: - iPad back button after agent auto-restore regression tests

    @Test @MainActor func shouldRepushConversation_falseWhenUserNavigatedBack() {
        // Regression: the deferred iPad re-push used to check only the agent id,
        // so it re-pushed the conversation even after the coordinator had already
        // navigated back to .workspaceDetail — leaving the conversation visible
        // with a dead "< Agents" button.
        let repush = RootView.shouldRepushConversation(
            currentScreen: .workspaceDetail(workspaceId: "ws-1"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1")
        #expect(!repush, "Must not re-push the conversation when currentScreen is no longer .agentConversation")
    }

    @Test @MainActor func shouldRepushConversation_trueWhenStillOnSameConversation() {
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-1", workspaceId: "ws-1", agentName: "Worker"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1")
        #expect(repush, "Should re-push when the same conversation is still the current screen")
    }

    @Test @MainActor func shouldRepushConversation_falseWhenAgentChangedAgain() {
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-2", workspaceId: "ws-1", agentName: "Other"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-2")
        #expect(!repush, "A stale re-push for a superseded agent must be dropped")
    }

    @Test @MainActor func shouldRepushConversation_falseWhenCoordinatorMovedToAnotherAgent() {
        // Coordinator moved on to a different agent before the view state re-synced:
        // the screen match must reject the stale re-push even though the pending
        // and view-state agent ids still agree.
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-2", workspaceId: "ws-1", agentName: "Other"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1")
        #expect(!repush, "Re-push must be dropped when the coordinator now shows a different conversation")
    }

    @Test @MainActor func onBackToWorkspaceDetail_fromConversation_setsWorkspaceDetail() {
        let wsId = "test-coord-back-from-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        coordinator.onBackToWorkspaceDetail()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after onBackToWorkspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onBackToWorkspaceDetail_idempotentWhenAlreadyOnDetail() {
        let wsId = "test-coord-back-idempotent-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        coordinator.onBackToWorkspaceDetail()
        // Simulate the desynced state: a second back tap while already on .workspaceDetail
        // (with a stale saved conversation screen) must stay on detail and keep it cleared.
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-1", agentName: "Worker",
                noteId: nil, noteTitle: nil))
        coordinator.onBackToWorkspaceDetail()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after repeated onBackToWorkspaceDetail, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Repeated onBackToWorkspaceDetail should still clear the per-workspace screen")
    }

    // MARK: - Fetch-driven workspace validation (lastUpdated race)

    private static func makeWorkspace(id: String, status: String? = nil,
                                      attention: String? = nil) -> Workspace {
        Workspace(
            id: id, title: "WS \(id)", branch: nil, baseRef: nil,
            status: status, activity: nil, displayStatus: nil,
            attention: attention,
            lastActivity: nil, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil,
            prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil,
            taskStatsCompleted: nil, taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    /// Let main-queue-hopping sinks and spawned validation tasks run.
    private static func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - workspace.markSeen on open

    @Test @MainActor func onSelectWorkspace_callsMarkSeenAndClearsUnreadLocally() async {
        let wsId = "test-coord-markseen-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.markSeen"] = ["workspace": ["id": wsId]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("workspace.markSeen"))
        #expect(fake.paramsForMethod("workspace.markSeen").first?["workspaceId"] as? String == wsId)
        #expect(store.workspaces.first?.attention == "none",
                "Opening a workspace must optimistically clear the local unread flag")
    }

    @Test @MainActor func onConnectionSuccess_restoreIntoWorkspaceMarksSeen() async {
        let wsId = "test-coord-restore-markseen-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Cold-start restore into a workspace counts as viewing it (mirrors
        // the FE, which marks seen whenever the workspace surface activates).
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: wsId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
            for: Self.windowBackend.connectionID)

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.markSeen"] = ["workspace": ["id": wsId]] as [String: Any]
        let coordinator = AppCoordinator(
            workspaceStore: store, connection: fake,
            backendID: Self.windowBackend, persistence: persistence)

        coordinator.onConnectionSuccess()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("workspace.markSeen"))
        #expect(fake.paramsForMethod("workspace.markSeen").first?["workspaceId"] as? String == wsId)
        #expect(store.workspaces.first?.attention == "none",
                "Restoring into a workspace must clear the local unread flag")
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_markSeenFailureIsIgnored() async {
        let wsId = "test-coord-markseen-fail-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        // Older daemon without the method — must not disturb navigation
        fake.errorMap["workspace.markSeen"] = NSError(
            domain: "WebSocket", code: -32601,
            userInfo: [NSLocalizedDescriptionKey: "Method not found"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("markSeen failure must not affect navigation, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func firstFetch_missingWorkspace_bootsToWorkspaceList() async {
        let wsId = "test-coord-firstfetch-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(
            workspaceStore: store, connection: FakeConnectionManager(),
            backendID: Self.windowBackend, persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        // Regression: the very first post-launch fetch must trigger validation
        // (lastUpdated used to be assigned after workspaces, so the first publish was skipped).
        // An empty first response must still invalidate Observation through the
        // fetch marker even though the workspace array remains empty.
        store.publishFetchedWorkspaces([])
        await Self.drainMainQueue()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after first fetch without the workspace, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID) == nil,
                "Last screen should be cleared")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil, "Per-workspace screen should be cleared")
    }

    @Test @MainActor func preFetchEmptyPublish_doesNotBootUserOut() async {
        let wsId = "test-coord-prefetch-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        // A publish before any successful fetch (lastUpdated still nil) must be ignored.
        store.workspaces = []
        await Self.drainMainQueue()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("An empty pre-fetch publish must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func firstFetch_archivedWorkspace_bootsToWorkspaceListFromConversation() async {
        let wsId = "test-coord-archived-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, status: "archived")])
        await Self.drainMainQueue()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList for archived workspace, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func firstFetch_existingWorkspace_staysOnDetail() async {
        let wsId = "test-coord-alive-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])
        await Self.drainMainQueue()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected to stay on .workspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Auto-open a sole top-level agent on workspace entry

    private static func makeAgent(
        id: String,
        name: String = "Worker",
        isBackground: Bool = false,
        createdByAgentId: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, name: name, status: "Idle",
            isBackground: isBackground, isStreaming: false,
            isProcessing: false, isResponding: false,
            isWaitingForOtherAgents: false, waitingForAgentIds: [],
            createdAt: nil, updatedAt: nil, lastActivity: nil,
            lastAgentResponse: nil, lastUserMessage: nil,
            lastMessageRole: nil, digest: nil, specialist: nil,
            createdByAgentId: createdByAgentId,
            attentionRequestKind: nil, attentionRequestReason: nil,
            attentionRequestTimestamp: nil)
    }

    /// The agent list feeds the coordinator its `foregroundAgents`; building
    /// them through the view model keeps the "top-level only" rule under test.
    @MainActor private static func foregroundAgents(_ agents: [AgentSession]) -> [AgentSession] {
        let viewModel = AgentListViewModel()
        viewModel.agents = agents
        return viewModel.foregroundAgents
    }

    @Test @MainActor func autoOpenSoleAgent_opensTheOnlyTopLevelAgent() {
        let wsId = "test-coord-autoopen-one-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([
                Self.makeAgent(id: "agent-solo", name: "Solo"),
                Self.makeAgent(id: "agent-bg", name: "Hook", isBackground: true),
                Self.makeAgent(id: "agent-sub", name: "Delegate", createdByAgentId: "agent-solo"),
            ]))

        if case .agentConversation(let agentId, let wId, let agentName) = coordinator.currentScreen {
            #expect(agentId == "agent-solo")
            #expect(wId == wsId)
            #expect(agentName == "Solo")
        } else {
            Issue.record(
                "Expected to continue into the sole top-level agent, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_staysOnListForSeveralTopLevelAgents() {
        let wsId = "test-coord-autoopen-many-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([
                Self.makeAgent(id: "agent-1", name: "One"),
                Self.makeAgent(id: "agent-2", name: "Two"),
            ]))

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Two top-level agents must keep the agent list, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_staysOnListWithNoTopLevelAgents() {
        let wsId = "test-coord-autoopen-none-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([
                Self.makeAgent(id: "agent-bg", name: "Hook", isBackground: true),
            ]))

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("A background-only workspace must keep the agent list, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_doesNotReForwardAfterBack() {
        let wsId = "test-coord-autoopen-back-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let agents = Self.foregroundAgents([Self.makeAgent(id: "agent-solo", name: "Solo")])
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.autoOpenSoleAgentIfArmed(workspaceId: wsId, foregroundAgents: agents)
        coordinator.onBackToWorkspaceDetail()

        // The agent list reappearing (and refetching) must not forward again.
        coordinator.autoOpenSoleAgentIfArmed(workspaceId: wsId, foregroundAgents: agents)

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Back from the auto-opened conversation must stay on the agent list, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_notArmedByRestoredSubScreen() async {
        let wsId = "test-coord-autoopen-restore-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-live", noteTitle: "Live Note"))

        let fake = FakeConnectionManager()
        fake.responseMap["note.get"] = ["note": [
            "id": "note-live", "title": "Live Note", "content": "hello"
        ] as [String: Any]] as [String: Any]
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake,
            persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()
        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([Self.makeAgent(id: "agent-solo")]))

        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-live")
            #expect(wId == wsId)
        } else {
            Issue.record("A restored sub-screen must not be replaced by the auto-open, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_notArmedByColdStartRestore() {
        let wsId = "test-coord-autoopen-coldstart-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: wsId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
            for: Self.windowBackend.connectionID)

        let coordinator = AppCoordinator(
            backendID: Self.windowBackend, persistence: persistence)
        coordinator.onConnectionSuccess()
        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([Self.makeAgent(id: "agent-solo")]))

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Restoring the agent list must not auto-forward, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_cancelledArmDoesNotForward() {
        let wsId = "test-coord-autoopen-cancel-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        // The workspace restored to its Context tab: the view consumes the arm.
        coordinator.cancelPendingAutoOpen(workspaceId: wsId)

        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([Self.makeAgent(id: "agent-solo", name: "Solo")]))

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("A cancelled arm must never forward, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_cancelForOtherWorkspaceKeepsArm() {
        let wsId = "test-coord-autoopen-cancel-other-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        // A stale cancel for another workspace must not disarm this entry.
        coordinator.cancelPendingAutoOpen(workspaceId: "ws-other")

        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([Self.makeAgent(id: "agent-solo", name: "Solo")]))

        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-solo")
            #expect(wId == wsId)
        } else {
            Issue.record("A cancel for another workspace must keep the arm, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func autoOpenSoleAgent_droppedWhenUserNavigatedOnWhileLoading() {
        let wsId = "test-coord-autoopen-raced-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        // A notification tap opened another agent before the list finished loading.
        coordinator.onSelectAgent("agent-tapped", workspaceId: wsId, agentName: "Tapped")

        coordinator.autoOpenSoleAgentIfArmed(
            workspaceId: wsId,
            foregroundAgents: Self.foregroundAgents([Self.makeAgent(id: "agent-solo", name: "Solo")]))

        if case .agentConversation(let agentId, _, _) = coordinator.currentScreen {
            #expect(agentId == "agent-tapped",
                    "A late auto-open must not replace the conversation the user already opened")
        } else {
            Issue.record("Expected to stay on the tapped conversation, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Reconnect re-validation of the open conversation

    @Test @MainActor func repeatedReconnectAttemptsDoNotFanOutWorkspaceLoadingChanges() async {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            persistence: persistence,
            reconnectLoadingObservationDidChange: {
                callbackCount.withLock { $0 += 1 }
            })

        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()

        // Repeated connected events replace the pending reconnect attempt while
        // the overlay is still waiting for workspace loading to complete.
        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline + 1,
                "Only the current reconnect registration may receive a loading change")
        #expect(coordinator.isDisconnected)

        store.isLoading = false
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline + 2)
        #expect(!coordinator.isDisconnected,
                "The overlay must clear when workspace loading finishes")
    }

    @Test @MainActor func reconnectTimeoutRemovesWorkspaceLoadingObservation() async throws {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            persistence: persistence,
            reconnectLoadingObservationDidChange: {
                callbackCount.withLock { $0 += 1 }
            })

        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()

        try await Task.sleep(for: .milliseconds(5_200))
        #expect(!coordinator.isDisconnected)

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline,
                "A timed-out reconnect must not leave a loading callback registered")
    }

    @Test @MainActor func coordinatorDeallocationRemovesWorkspaceLoadingObservation() async {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        weak var weakCoordinator: AppCoordinator?

        do {
            var coordinator: AppCoordinator? = AppCoordinator(
                workspaceStore: store,
                connection: fake,
                persistence: persistence,
                reconnectLoadingObservationDidChange: {
                    callbackCount.withLock { $0 += 1 }
                })
            weakCoordinator = coordinator

            fake.simulateConnect()
            await Self.drainMainQueue()
            fake.simulateDisconnect()
            await Self.drainMainQueue()
            fake.simulateConnect()
            await Self.drainMainQueue()
            coordinator = nil
        }

        await Self.drainMainQueue()
        #expect(weakCoordinator == nil)

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline,
                "Deallocation must consume the pending loading registration")
    }

    @Test @MainActor func staleOverlayTimeoutDoesNotHideLaterDisconnection() async throws {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            persistence: persistence,
            reconnectLoadingObservationDidChange: {
                callbackCount.withLock { $0 += 1 }
            })

        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()

        #expect(coordinator.isDisconnected)
        try await Task.sleep(for: .milliseconds(5_200))
        #expect(coordinator.isDisconnected,
                "A timeout from the prior reconnect must not hide a later disconnection")

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()
        #expect(callbackCount.withLock { $0 } == baseline,
                "Disconnect must consume the pending loading registration")
    }

    @Test @MainActor func reconnect_missingAgent_bootsToWorkspaceDetail() async {
        let wsId = "test-coord-reconnect-gone-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "agent not found",
                       NSError.intentErrorDataCodeKey: "not-found"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        // Seed the store so the reconnect overlay clears immediately.
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-gone", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"), "Reconnect must re-validate the open conversation's agent")
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after reconnect with missing agent, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved sub-screen should be cleared for the missing agent")
    }

    @Test @MainActor func reconnect_agentStillExists_staysOnConversation() async {
        let wsId = "test-coord-reconnect-alive-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = ["agent": ["id": "agent-live"]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-live")
            #expect(wId == wsId)
        } else {
            Issue.record("Expected to stay on .agentConversation after reconnect, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func reconnect_agentTransientError_staysOnConversation() async {
        let wsId = "test-coord-reconnect-transient-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-live")
            #expect(wId == wsId)
        } else {
            Issue.record("Transient agent.get error must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func reconnect_agentBare32602_staysOnConversation() async {
        let wsId = "test-coord-reconnect-bare32602-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-live")
            #expect(wId == wsId)
        } else {
            Issue.record("A -32602 without data.code == \"not-found\" must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func reconnect_notOnConversation_doesNotValidateAgent() async {
        let wsId = "test-coord-reconnect-detail-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectWorkspace(wsId)
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(!fake.didCallMethod("agent.get"), "agent.get must not be called when not on a conversation screen")
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after reconnect, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Missing agent handling (conversation fallback)

    @Test @MainActor func handleMissingAgent_navigatesToWorkspaceDetail_andClearsSavedScreen() {
        let wsId = "test-coord-missing-agent-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-gone", workspaceId: wsId, agentName: "Doomed")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil)

        coordinator.handleMissingAgent(agentId: "agent-gone", workspaceId: wsId)

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after handleMissingAgent, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved sub-screen should be cleared for the missing agent")
    }

    @Test @MainActor func handleMissingAgent_ignoredWhenNotOnConversationScreen() {
        // Self-initiated deletion dismisses the conversation first, so by the
        // time the agent:deleted fallback fires the screen is already
        // .workspaceDetail — the guard must make it a no-op (no double navigation).
        let wsId = "test-coord-missing-agent-noop-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        coordinator.handleMissingAgent(agentId: "agent-1", workspaceId: wsId)

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent off a conversation must not navigate, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleMissingAgent_ignoredForDifferentWorkspace() {
        let wsId = "test-coord-missing-agent-otherws-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        coordinator.handleMissingAgent(agentId: "agent-1", workspaceId: "some-other-workspace")

        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent for another workspace must not navigate, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleMissingAgent_ignoredForDifferentAgent() {
        // A stale validation for agent A must not evict a live conversation
        // with agent B in the same workspace.
        let wsId = "test-coord-missing-agent-otheragent-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-b", workspaceId: wsId, agentName: "Alive")

        coordinator.handleMissingAgent(agentId: "agent-a", workspaceId: wsId)

        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-b")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent for another agent must not navigate, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil,
                "The live conversation's saved sub-screen must not be cleared")
    }

    // MARK: - Missing note handling

    @Test @MainActor func handleMissingNote_navigatesToWorkspaceDetail_andClearsSavedScreen() {
        let wsId = "test-coord-missing-note-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-gone", workspaceId: wsId, noteTitle: "Doomed Note")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil)

        coordinator.handleMissingNote(noteId: "note-gone", workspaceId: wsId)

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after handleMissingNote, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved note screen should be cleared for the missing note")
    }

    @Test @MainActor func handleMissingNote_ignoredWhenNotOnNoteScreen() {
        let wsId = "test-coord-missing-note-noop-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        coordinator.handleMissingNote(noteId: "note-1", workspaceId: wsId)

        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingNote must not navigate away from a conversation, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleMissingNote_ignoredForDifferentWorkspace() {
        let wsId = "test-coord-missing-note-otherws-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-1", workspaceId: wsId, noteTitle: "Note")

        coordinator.handleMissingNote(noteId: "note-1", workspaceId: "some-other-workspace")

        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-1")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingNote for another workspace must not navigate, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleMissingNote_ignoredForDifferentNote() {
        // A stale validation for note A must not evict a live note B screen
        // in the same workspace (reachable via note-to-note links).
        let wsId = "test-coord-missing-note-othernote-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-b", workspaceId: wsId, noteTitle: "Alive Note")

        coordinator.handleMissingNote(noteId: "note-a", workspaceId: wsId)

        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-b")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingNote for another note must not navigate, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil,
                "The live note screen's saved sub-screen must not be cleared")
    }

    // MARK: - Note validation on restore

    @Test @MainActor func onSelectWorkspace_restoredNoteMissing_fallsBackToDetail() async {
        let wsId = "test-coord-restore-dead-note-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-dead", noteTitle: "Dead Note"))

        // No workspace publish: keep lastUpdated nil so the workspace-existence
        // validation stays inert and only the note validation path is exercised.
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // note.get answers -32602 with data.code == "not-found" for a
        // nonexistent note (docs/PROTOCOL.md §3.3/§9)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "note not found",
                       NSError.intentErrorDataCodeKey: "not-found"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("note.get"), "Restoring a note screen must re-validate the note")
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after restoring a missing note, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved note screen should be cleared for the missing note")
    }

    @Test @MainActor func onSelectWorkspace_restoredNoteTransientError_staysOnNote() async {
        let wsId = "test-coord-restore-note-transient-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-1", noteTitle: "Flaky Network Note"))

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-1")
            #expect(wId == wsId)
        } else {
            Issue.record("Transient note.get error must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_restoredNoteAlive_staysOnNote() async {
        let wsId = "test-coord-restore-note-alive-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-live", noteTitle: "Live Note"))

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.responseMap["note.get"] = ["note": [
            "id": "note-live", "title": "Live Note", "content": "hello"
        ] as [String: Any]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("note.get"))
        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-live")
            #expect(wId == wsId)
        } else {
            Issue.record("Expected to stay on .noteDetail for a live note, got \(coordinator.currentScreen)")
        }
    }
}

