import Foundation
@testable import Intent
import Synchronization
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func startupConnectionEventsNeverArmLossOverlay() async {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbacks = Mutex(0)
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence) {
            callbacks.withLock { $0 += 1 }
        }
        let screens: [AppScreen] = [.loading, .connecting, .pairing, .connectionFailed(error: "timeout"), .disconnected]
        for screen in screens {
            coordinator.currentScreen = screen
            store.isLoading = true
            let states: [ConnectionState] = [.disconnected, .connecting, .connected, .reconnecting(attempt: 1), .connected]
            for state in states {
                fake.connectionState = state
                await Self.drainStartupCallbacks()
                #expect(!coordinator.isDisconnected)
                #expect(!coordinator.showsConnectionLossOverlay)
                #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
            }
            store.isLoading = false
            await Self.drainStartupCallbacks()
        }
        #expect(callbacks.withLock { $0 } == 0, "Startup must not register recovery observations")
    }

    @Test @MainActor func savedBackendStartupDropKeepsBoundedFallbackWithoutOverlay() async {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        saveWorkspaceListScreen(for: stored)
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(
            workspaceStore: store, connection: fake, backendID: BackendID(stored.id), persistence: persistence
        )
        coordinator.onLoadComplete()
        #expect(coordinator.currentScreenDescription == "connecting")
        fake.simulateConnect()
        await Self.drainStartupCallbacks()
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(!coordinator.isDisconnected)
        // The real data wait can finish through either data arrival or its timeout.
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        #expect(coordinator.currentScreenDescription == "workspaceList")
        #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
        fake.simulateConnect()
        await Self.drainStartupCallbacks()
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(!coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func startupRetryArmsOnlyAfterSuccessfulEntry() async {
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake, persistence: persistence
        )
        coordinator.onConnectionFailed(error: "timeout")
        coordinator.onRetryConnection()
        fake.simulateConnect()
        await Self.drainStartupCallbacks()
        fake.connectionState = .reconnecting(attempt: 1)
        await Self.drainStartupCallbacks()
        #expect(!coordinator.showsConnectionLossOverlay)
        fake.simulateConnect()
        await Self.drainStartupCallbacks()
        coordinator.dependencies.workspaceStore.publishFetchedWorkspaces([])
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        #expect(coordinator.currentScreenDescription == "workspaceList")
        #expect(!coordinator.isDisconnected, "No loss state from startup may leak into the remote UI")
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func leavingRemoteUIResetsEligibilityAndPendingRecovery() async {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(forTesting: true)
        let callbacks = Mutex(0)
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence) {
            callbacks.withLock { $0 += 1 }
        }
        let screens: [AppScreen] = [.loading, .connecting, .pairing, .connectionFailed(error: "timeout"), .disconnected]
        for screen in screens {
            fake.simulateConnect()
            await Self.drainStartupCallbacks()
            store.publishFetchedWorkspaces([])
            coordinator.onConnectionSuccess()
            store.lastUpdated = nil // Exercise a recovery that must await a fresh snapshot.
            fake.simulateDisconnect()
            await Self.drainStartupCallbacks()
            #expect(coordinator.showsConnectionLossOverlay)
            fake.simulateConnect()
            await Self.drainStartupCallbacks()
            store.isLoading = true // Queues a recovery callback that must not re-arm in the next flow.
            coordinator.currentScreen = screen
            await Self.drainStartupCallbacks()
            let baseline = callbacks.withLock { $0 }
            store.isLoading = false
            await Self.drainStartupCallbacks()
            #expect(callbacks.withLock { $0 } == baseline)
            #expect(!coordinator.isDisconnected)
            #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
            fake.simulateDisconnect()
            await Self.drainStartupCallbacks()
            #expect(!coordinator.showsConnectionLossOverlay)
        }
    }

    @Test @MainActor func staleInitialCompletionCannotReplaceFailurePairingOrHome() {
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake, persistence: persistence
        )
        fake.simulateConnect()
        let screens: [AppScreen] = [.connectionFailed(error: "certificate"), .pairing, .workspaceList]
        for screen in screens {
            coordinator.currentScreen = screen
            let description = coordinator.currentScreenDescription
            coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
            #expect(coordinator.currentScreenDescription == description)
            #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
        }
        coordinator.onReturnToSavedMachines()
        fake.simulateConnect()
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        #expect(coordinator.currentScreenDescription == "pairing")
        #expect(!coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func switchAndReselectRequireFreshSuccessfulEntry() async {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let other = persistence.upsertConnection(Self.makeConnection(port: 5252))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake, persistence: persistence
        )
        for target in [stored, other, other] {
            coordinator.onSwitchConnection(id: target.id)
            fake.simulateConnect()
            await Self.drainStartupCallbacks()
            fake.simulateDisconnect()
            await Self.drainStartupCallbacks()
            #expect(!coordinator.showsConnectionLossOverlay)
            fake.simulateConnect()
            await Self.drainStartupCallbacks()
            coordinator.dependencies.workspaceStore.publishFetchedWorkspaces([])
            coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
            fake.simulateDisconnect()
            await Self.drainStartupCallbacks()
            #expect(coordinator.showsConnectionLossOverlay)
        }
    }

    @Test @MainActor func successfulEntryArmsLossForRestorationNotificationAndSettings() async {
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        saveWorkspaceListScreen(for: stored)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence
        )
        coordinator.onLoadComplete()
        fake.simulateConnect()
        await Self.drainStartupCallbacks()
        coordinator.dependencies.workspaceStore.publishFetchedWorkspaces([Self.makeWorkspace(id: "workspace")])
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(coordinator.showsConnectionLossOverlay)
        coordinator.onRetryConnection()
        coordinator.handleNotificationSelection(
            agentId: "agent", workspaceId: "workspace", agentName: "Agent", connectionId: stored.id
        )
        fake.simulateConnect()
        await Self.drainStartupCallbacks()
        coordinator.dependencies.workspaceStore.publishFetchedWorkspaces([Self.makeWorkspace(id: "workspace")])
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        if case .agentConversation = coordinator.currentScreen {} else { Issue.record("Expected notification route") }
        coordinator.onOpenSettings()
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func queuedStartupLossCannotAppearAfterSuccessfulEntry() async {
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake, persistence: persistence
        )
        coordinator.onRetryConnection()
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        coordinator.dependencies.workspaceStore.publishFetchedWorkspaces([])
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        await Self.drainStartupCallbacks()
        #expect(coordinator.currentScreenDescription == "workspaceList")
        #expect(!coordinator.isDisconnected, "Queued startup states must not create a recovery wait after entry")
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(coordinator.showsConnectionLossOverlay, "A fresh established-session loss must still present")
    }

    @Test @MainActor func supersededInitialDataWaitCannotCompleteReplacementAttempt() {
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true), connection: fake, persistence: persistence
        )
        coordinator.onRetryConnection()
        let oldAttempt = coordinator.connectionAttemptId
        fake.simulateConnect()
        coordinator.restartConnectionAttempt()
        coordinator.onInitialWorkspaceLoadComplete(attemptID: oldAttempt)
        #expect(coordinator.currentScreenDescription == "connecting")
        #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
        #expect(!coordinator.isDisconnected)
        coordinator.dependencies.workspaceStore.publishFetchedWorkspaces([])
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        #expect(coordinator.currentScreenDescription == "workspaceList")
        #expect(coordinator.lifecycleState.hasEnteredRemoteUI)
    }

    @Test @MainActor func firstWorkspaceTimeoutDoesNotArmOverlayOnRealTransport() async throws {
        let previous = ConnectionManagerTests.enablePlaintextLoopback()
        defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }
        let server = try await RecoveryWebSocketServer.start()
        server.failNextRequests(2, method: "workspace.list")
        let manager = ConnectionManager()
        let store = WorkspaceStore(connectionManager: manager)
        let coordinator = AppCoordinator(workspaceStore: store, connection: manager, persistence: persistence)
        defer {
            manager.disconnect()
            server.stop()
        }
        coordinator.onRetryConnection()
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: UUID().uuidString)
        try await waitUntil("first workspace request failed without usable data") {
            server.requestCount(method: "workspace.list") == 1 && !store.isLoading
        }
        let loaded = try await LaunchPhaseTimeline.poll(
            until: { store.lastUpdated != nil },
            timeout: Constants.Connecting.workspaceLoadTimeout,
            interval: Constants.Connecting.workspacePollInterval
        )
        #expect(!loaded)
        #expect(manager.connectionState == .connected)
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        #expect(!coordinator.lifecycleState.hasEnteredRemoteUI, "A socket without its first data is still startup")

        server.dropClients()
        try await waitUntil("the actual socket enters automatic reconnect") {
            if case .reconnecting = manager.connectionState { return true }
            return false
        }
        await Self.drainStartupCallbacks()
        #expect(!coordinator.showsConnectionLossOverlay, "First-data timeout must not expose the loss overlay")
        #expect(coordinator.currentScreenDescription == "workspaceList", "Keep the bounded navigation fallback")
        try await waitUntil("automatic reconnect and its failed first-data request finish") {
            manager.connectionState == .connected && server.requestCount(method: "workspace.list") == 2 && !store.isLoading
        }
        await store.fetchAll()
        #expect(server.requestCount(method: "workspace.list") == 3, "Retry must issue a fresh request")
        #expect(store.lastUpdated != nil, "The successful retry must publish usable data")
        try await waitUntil("late usable data enables established-session loss") {
            coordinator.lifecycleState.hasEnteredRemoteUI
        }
        server.dropClients()
        try await waitUntil("a later established-session loss presents") { coordinator.showsConnectionLossOverlay }
        try await waitUntil("established reconnect clears the overlay", timeout: .seconds(5)) {
            manager.connectionState == .connected && !coordinator.showsConnectionLossOverlay
        }
    }

    @Test(arguments: [true, false]) @MainActor
    func pairingAndFailureRetryRequireFreshData(pairing: Bool) async throws {
        let stored = Self.makeConnection(port: 4242)
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([]) // Cached data from before this initial flow is insufficient.
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        if pairing {
            coordinator.currentScreen = .pairing
        } else {
            coordinator.onConnectionFailed(error: "timeout")
        }
        fake.simulateConnect()
        if pairing {
            coordinator.onPaired(stored)
        } else {
            coordinator.onConnectionSuccess() // ConnectionFailureView's automatic retry completion.
        }
        await Self.drainStartupCallbacks()
        #expect(coordinator.currentScreenDescription == "workspaceList")
        #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(!coordinator.showsConnectionLossOverlay)

        fake.simulateConnect()
        store.publishFetchedWorkspaces([]) // An empty but successful fresh snapshot is usable data.
        try await waitUntil("fresh data after pairing/retry arms subsequent loss") {
            coordinator.lifecycleState.hasEnteredRemoteUI
        }
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func retryCannotReuseThePreviousAttemptsWorkspaceData() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        coordinator.onRetryConnection()
        fake.simulateConnect()
        store.publishFetchedWorkspaces([])
        coordinator.restartConnectionAttempt()
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        await Self.drainStartupCallbacks()
        #expect(!coordinator.lifecycleState.hasEnteredRemoteUI)
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(!coordinator.showsConnectionLossOverlay)
        fake.simulateConnect()
        store.publishFetchedWorkspaces([])
        try await waitUntil("replacement attempt receives fresh data") { coordinator.lifecycleState.hasEnteredRemoteUI }
        fake.simulateDisconnect()
        await Self.drainStartupCallbacks()
        #expect(coordinator.showsConnectionLossOverlay)
    }

    @MainActor private static func drainStartupCallbacks() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
