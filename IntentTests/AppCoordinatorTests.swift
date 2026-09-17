import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

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
            claimScreenRestoration: claimScreenRestoration
        )
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
    let persistence: PersistenceManager
    private let suiteName: String

    /// Backend identity for tests that bind the coordinator to a window
    /// backend without needing a saved connection record. Sharing it across
    /// tests is safe: each test's persistence uses its own UserDefaults suite.
    static let windowBackend = BackendID(UUID())

    init() throws {
        // The coordinator under test uses the injected per-test persistence,
        // but non-injected globals (e.g. ConnectionManager.shared's route
        // refresh) can still reach PersistenceManager.shared — keep its
        // keychain in-memory so SecItem is never hit in headless CI.
        _ = TestKeychainStorage.installed
        suiteName = "AppCoordinatorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults,
            keychainStorage: InMemoryKeychainStorage()
        )
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
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: "restored-workspace",
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: stored.id
        )
        let coordinator = AppCoordinator(
            backendID: BackendID(stored.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )

        coordinator.handleNotificationSelection(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent",
            connectionId: stored.id
        )
        coordinator.onLoadComplete()
        if case .connecting = coordinator.currentScreen {
            // Normal cold-start routing remains in control until connection succeeds.
        } else {
            Issue.record("Expected .connecting before connection success, got \(coordinator.currentScreen)")
        }

        coordinator.onConnectionSuccess()

        if case let .agentConversation(agentId, workspaceId, agentName) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(workspaceId == "workspace-1")
            #expect(agentName == "Build Agent")
        } else {
            Issue.record("Expected notification to win over restoration, got \(coordinator.currentScreen)")
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
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent",
            connectionId: stored.id
        )
        if case .connectionFailed = coordinator.currentScreen {} else {
            Issue.record("Notification replaced the connection failure screen")
        }
        coordinator.onRetryConnection()
        coordinator.onConnectionSuccess()
        if case let .agentConversation(agentId, _, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
        } else {
            Issue.record("Expected deferred notification after retry")
        }

        coordinator.currentScreen = .disconnected
        coordinator.handleNotificationSelection(
            agentId: "agent-2",
            workspaceId: "workspace-2",
            agentName: "Test Agent",
            connectionId: stored.id
        )
        if case .disconnected = coordinator.currentScreen {} else {
            Issue.record("Notification replaced the disconnected screen")
        }
        coordinator.onRetryConnection()
        coordinator.onConnectionSuccess()
        if case let .agentConversation(agentId, _, _) = coordinator.currentScreen {
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
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent",
            connectionId: second.id
        )

        coordinator.onConnectionSuccess()

        if case .workspaceList = coordinator.currentScreen {} else {
            Issue.record("A notification for another backend must not route in this window")
        }
    }

    @Test @MainActor func onConnectionFailed_setsConnectionFailed() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onConnectionFailed(error: "timeout")
        #expect(coordinator.connectionFailureRetryPolicy == .automaticConnection)
        if case let .connectionFailed(error) = coordinator.currentScreen {
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
        #expect(
            retargeted == [BackendID(stored.id)],
            "A pairing must route to the paired backend's window"
        )
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
            [Self.makeWorkspace(id: "ws-paired-daemon", attention: "none")]
        )
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: BackendID(own.id),
            persistence: persistence
        )
        coordinator.currentScreen = .workspaceList
        var retargeted: [BackendID] = []
        coordinator.retargetWindow = { retargeted.append($0) }

        coordinator.onPaired(paired)

        #expect(
            retargeted == [BackendID(paired.id)],
            "The pairing must still route to the paired backend's window"
        )
        #expect(
            fake.disconnectCallCount == 1,
            "The hijacked socket must be dropped"
        )
        #expect(
            store.workspaces.isEmpty,
            "The paired daemon's workspace data must be dropped"
        )
        if case .connecting = coordinator.currentScreen {} else {
            Issue.record("Expected a re-dial of this window's own backend, got \(coordinator.currentScreen)")
        }
    }

    /// A re-pair routed for this window's own backend must not trigger the
    /// repair re-dial (no disconnect, screen untouched).
}

extension AppCoordinatorTests {
    @Test func retargetRouteRebindsInPlaceWhenTargetIsCurrentBackend() {
        let current = BackendID(UUID())
        #expect(
            WindowRetargetRoute.route(
                currentBackendID: current,
                target: current,
                supportsMultipleWindows: true
            ) == .rebindInPlace,
            "Switching to the backend the window is already bound to stays in place"
        )
    }

    @Test @MainActor func firstFetch_archivedWorkspace_bootsToWorkspaceListFromConversation() async {
        let wsId = "test-coord-archived-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

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

    @Test @MainActor func onPaired_boundWindow_sameBackend_noRedial() {
        let own = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            backendID: BackendID(own.id),
            persistence: persistence
        )
        coordinator.currentScreen = .workspaceList
        var retargeted: [BackendID] = []
        coordinator.retargetWindow = { retargeted.append($0) }

        coordinator.onPaired(own)

        #expect(retargeted == [BackendID(own.id)])
        #expect(
            fake.disconnectCallCount == 0,
            "A same-backend pairing must not drop this window's connection"
        )
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
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            persistence: persistence
        )
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
}
