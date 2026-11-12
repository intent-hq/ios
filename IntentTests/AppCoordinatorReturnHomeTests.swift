import Foundation
@testable import Intent
import Synchronization
import Testing

extension AppCoordinatorTests {
    // Guard the legacy view's actual button wiring, not just the coordinator
    // behavior below: relabeling the old destructive action must still fail.
    @Test func legacyDisconnectedExitUsesNonDestructiveHomeAction() throws {
        let source = try String(
            contentsOf: TestSourceInputs.url(for: "Intent/Views/Connection/DisconnectedView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Button(action: coordinator.onReturnToSavedMachines)"))
        #expect(source.contains("Text(\"Back to Home\")"))
        #expect(source.contains(".accessibilityIdentifier(\"disconnected.home\")"))
        #expect(source.contains("Return to your saved machines without forgetting this connection."))
        #expect(!source.contains("onLogOff"))
        #expect(!source.contains(".disconnect("))
        #expect(!source.contains("Log Off"))
    }

    @Test(arguments: [nil, .automaticConnection, .manualLogOff] as [ConnectionFailureRetryPolicy?])
    @MainActor func returnHomeKeepsSavedConnectionsAndCredentials(failurePolicy: ConnectionFailureRetryPolicy?) {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let other = persistence.upsertConnection(Self.makeConnection(port: 5252))
        persistence.setActiveConnection(id: stored.id)
        saveWorkspaceListScreen(for: stored)
        let records = persistence.loadConnections()
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: "workspace")])
        let registry = BackendSessionRegistry()
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence,
            sessionRegistry: registry
        )
        coordinator.selectedWorkspaceId = "workspace"
        coordinator.connectionLoss = .lost
        if let failurePolicy {
            coordinator.routeToConnectionFailure(error: "Connection unavailable", retryPolicy: failurePolicy)
        }

        coordinator.onReturnToSavedMachines()
        coordinator.onReturnToSavedMachines()

        #expect(coordinator.currentScreenDescription == "pairing")
        #expect(coordinator.pairingShowsSavedConnections)
        #expect(!coordinator.isDisconnected)
        #expect(coordinator.selectedWorkspaceId == nil)
        #expect(persistence.loadConnections() == records)
        #expect(persistence.lastUsedConnection()?.id == stored.id)
        #expect(persistence.loadLastScreen(for: stored.id)?.screen == "workspaceList")
        #expect(registry.removedBackendIDs.isEmpty)
        #expect(persistence.loadConnections().contains { $0.id == other.id })
        #expect(fake.disconnectCallCount == 1)
        #expect(store.workspaces.isEmpty)
    }

    @Test @MainActor func returnHomeIgnoresQueuedAndLateConnectionEvents() async {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence
        )
        coordinator.handleNotificationSelection(
            agentId: "old-agent", workspaceId: "old-workspace", agentName: "Old", connectionId: stored.id
        )
        coordinator.currentScreen = .connecting
        let abandonedAttempt = coordinator.connectionAttemptId
        fake.simulateConnect()
        fake.certMismatchDetected = true
        // Both publishers have queued deliveries on the main queue.
        coordinator.onReturnToSavedMachines()
        await Self.drainReturnHomeCallbacks()
        fake.simulateConnect()
        fake.connectionState = .reconnecting(attempt: 1)
        fake.certMismatchDetected = true
        coordinator.onInitialWorkspaceLoadComplete(attemptID: abandonedAttempt)
        coordinator.onConnectionSuccess()
        coordinator.onConnectionFailed(error: "Late failure")
        coordinator.onRetryConnection()
        coordinator.onLoadComplete()
        coordinator.onDeepLinkPaired(stored)
        await Self.drainReturnHomeCallbacks()

        #expect(coordinator.currentScreenDescription == "pairing")
        #expect(!coordinator.isDisconnected)
        #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
        #expect(coordinator.routingState.pendingNotificationSelection == nil)
        #expect(fake.certMismatchDetected, "The abandoned window must not consume a sibling's certificate event")
    }

    @Test @MainActor func returnHomeCancelsPendingWorkspaceRecoveryObservation() async {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbacks = Mutex(0)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            persistence: persistence
        ) {
            callbacks.withLock { $0 += 1 }
        }
        fake.simulateConnect()
        await Self.drainReturnHomeCallbacks()
        store.publishFetchedWorkspaces([])
        coordinator.onConnectionSuccess()
        store.setLastUpdated(nil) // Home must retire a pending fresh-data recovery.
        fake.simulateDisconnect()
        await Self.drainReturnHomeCallbacks()
        #expect(coordinator.isDisconnected)
        fake.simulateConnect()
        await Self.drainReturnHomeCallbacks()
        store.setLoading(true)
        coordinator.onReturnToSavedMachines()
        await Self.drainReturnHomeCallbacks()
        let baseline = callbacks.withLock { $0 }
        store.setLoading(false)
        await Self.drainReturnHomeCallbacks()

        #expect(callbacks.withLock { $0 } == baseline, "A queued recovery callback must not re-arm after Home")
        #expect(coordinator.currentScreenDescription == "pairing")
        #expect(!coordinator.isDisconnected)
    }

    @Test @MainActor func returnHomeCancelsReconnectTaskAndRetiresConnectionGeneration() {
        let connection = ConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: connection,
            persistence: persistence
        )
        let retry = Task { try? await Task.sleep(for: .seconds(60)) }
        connection.reconnectTask = Task { _ = await retry.value }
        let reconnect = connection.reconnectTask
        let generation = connection.connectionGeneration
        defer { retry.cancel() }
        connection.connectionState = .reconnecting(attempt: 1)

        coordinator.onReturnToSavedMachines()

        #expect(reconnect?.isCancelled == true)
        #expect(connection.reconnectTask == nil)
        #expect(connection.connectionGeneration > generation)
        #expect(connection.connectionState == .disconnected)
    }

    @Test @MainActor func returnHomeAllowsExplicitSameMachineSelectionWithoutWindowHook() async {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence
        )
        coordinator.onReturnToSavedMachines()
        let attempt = coordinator.connectionAttemptId

        coordinator.onSwitchConnection(id: stored.id)
        #expect(coordinator.currentScreenDescription == "connecting")
        #expect(coordinator.connectionAttemptId > attempt)
        #expect(coordinator.windowConnection?.id == stored.id)
        fake.simulateConnect()
        await Self.drainReturnHomeCallbacks()
        coordinator.dependencies.workspaceStore.publishFetchedWorkspaces([])
        coordinator.onConnectionSuccess()
        #expect(coordinator.currentScreenDescription == "workspaceList")
        fake.simulateDisconnect()
        await Self.drainReturnHomeCallbacks()
        #expect(coordinator.isDisconnected, "The newly selected session must observe connection loss again")
    }

    @MainActor private static func drainReturnHomeCallbacks() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test @MainActor func returnHomeStopsFailureRetryBeforeViewDisappears() async {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence
        )

        await ConnectionFailureView.runAutoRetry(
            retryPolicy: .automaticConnection,
            isCertMismatch: false,
            coordinator: coordinator,
            connection: fake,
            loadConnections: { [stored] },
            backoff: { _ in .zero },
            onAttempt: { _ in coordinator.onReturnToSavedMachines() }
        )

        #expect(fake.connectLog.isEmpty, "An abandoned view must not start another connection before onDisappear")
        #expect(coordinator.currentScreenDescription == "pairing")
    }
}
