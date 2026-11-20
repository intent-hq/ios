import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

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
    let persistence: PersistenceManager
    private let suiteName: String

    static let windowBackend = BackendID(UUID())

    init() throws {
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

    @Test @MainActor func onConnectionSuccess_setsWorkspaceList() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onConnectionSuccess()
        if case .workspaceList = coordinator.currentScreen {
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
}

extension AppCoordinatorTests {
    @Test @MainActor func firstFetch_archivedWorkspace_bootsToWorkspaceListFromConversation() async throws {
        let wsId = "test-coord-archived-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, status: "archived")])
        try await waitUntil(".workspaceList for an archived workspace") {
            Self.isWorkspaceList(coordinator.currentScreen)
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

    @Test @MainActor func onPaired_boundWindow_sameBackend_fromFailure_restartsInitialRouting() throws {
        try assertSameBackendPairingRestartsInitialRouting(from: .connectionFailed(error: "timeout"))
    }

    @Test @MainActor func onPaired_boundWindow_sameBackend_whileConnecting_restartsInitialRouting() throws {
        try assertSameBackendPairingRestartsInitialRouting(from: .connecting)
    }

    @MainActor
    private func assertSameBackendPairingRestartsInitialRouting(from screen: AppScreen) throws {
        let originalPort = 4242
        let refreshedPort = 5252
        let own = persistence.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"], port: originalPort, name: "Mac", pairedAt: Date(), certFingerprint: "aa:bb"
            ),
            token: "old-test-token"
        ))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            backendID: BackendID(own.id),
            persistence: persistence
        )
        coordinator.currentScreen = screen
        coordinator.retargetWindow = { _ in }
        let previousAttempt = coordinator.connectionAttemptId
        let paired = persistence.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.2"],
                port: refreshedPort,
                name: "Mac",
                pairedAt: Date(),
                certFingerprint: "aa:bb",
                tcAddress: "tc-test-refreshed"
            ),
            token: "new-test-token"
        ))
        #expect(paired.id == own.id)

        coordinator.onPaired(paired)

        #expect(coordinator.connectionAttemptId != previousAttempt, "Re-pairing must restart initial routing")
        if case .connecting = coordinator.currentScreen {} else {
            Issue.record("Expected a fresh connection attempt, got \(coordinator.currentScreen)")
        }
        #expect(fake.disconnectCallCount == 0, "Do not run the different-backend repair path")
        let cached = try #require(fake.updateCachedCredentialsLog.last)
        #expect(cached.hosts == paired.server.hosts)
        #expect(cached.port == refreshedPort)
        #expect(cached.token == "new-test-token")
        #expect(cached.certFingerprint == "aa:bb")
        #expect(cached.tcAddress == "tc-test-refreshed")
    }

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
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSettingsBack_setsWorkspaceList() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSettingsBack()
        if case .workspaceList = coordinator.currentScreen {
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onReconnect_setsPairing() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onReconnect()
        if case .pairing = coordinator.currentScreen {
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func initialScreen_isLoading() {
        let coordinator = AppCoordinator(persistence: persistence)
        if case .loading = coordinator.currentScreen {
        } else {
            Issue.record("Expected initial screen to be .loading, got \(coordinator.currentScreen)")
        }
    }
}
