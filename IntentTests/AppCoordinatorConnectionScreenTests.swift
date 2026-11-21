import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func connectionScreenKeepsOnlyTheVisibleScreensFields() {
        let launch = ConnectionScreen.connecting(startedByLaunch: true)
        let offer = ConnectionScreen.pairing(showsSavedConnections: true)
        #expect(launch.kept(on: .loading) == launch)
        #expect(launch.kept(on: .connecting) == launch)
        #expect(offer.kept(on: .pairing) == offer)
        #expect(offer.kept(on: .connecting) == .connecting(startedByLaunch: false))
        #expect(ConnectionScreen.other.kept(on: .loading) == .connecting(startedByLaunch: false))
        #expect(launch.kept(on: .pairing) == .pairing(showsSavedConnections: false))
        #expect(launch.kept(on: .workspaceList) == .other)
        #expect(offer.kept(on: .connectionFailed(error: "x")) == .other)
        #expect(offer.kept(on: .settings) == .other)
    }

    @Test @MainActor func launchSplashStateEndsWhenTheWindowLeavesConnecting() {
        resetConnectionState()
        defer { resetConnectionState() }
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            backendID: BackendID(stored.id),
            persistence: persistence,
            sessionRegistry: BackendSessionRegistry(),
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        #expect(coordinator.connectionScreen == .connecting(startedByLaunch: true))
        coordinator.onLoadComplete()
        #expect(coordinator.connectionScreen == .connecting(startedByLaunch: true))

        coordinator.onConnectionSuccess()
        #expect(coordinator.connectionScreen == .other)
        #expect(!coordinator.connectingStartedByLaunch)

        coordinator.restartConnectionAttempt()
        #expect(coordinator.connectionScreen == .connecting(startedByLaunch: false))
    }

    @Test @MainActor func pairingWithoutAFreshReadDoesNotReuseAnEarlierOffer() {
        resetConnectionState()
        defer { resetConnectionState() }
        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        _ = persistence.upsertConnection(Self.makeConnection(port: 5252))
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            backendID: BackendID(stored.id),
            persistence: persistence,
            sessionRegistry: BackendSessionRegistry(),
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()
        coordinator.onReconnect()
        #expect(coordinator.connectionScreen == .pairing(showsSavedConnections: true))

        coordinator.onPaired(stored)
        #expect(coordinator.connectionScreen == .connecting(startedByLaunch: false))
        coordinator.onConnectionFailed(error: "timeout")
        #expect(coordinator.connectionScreen == .other)

        #expect(persistence.saveDataToKeychain(
            data: Data("{\"v\": 99, \"schema\": \"future\"}".utf8),
            account: persistence.keychainAccountConnections
        ))
        coordinator.onReconnect()
        #expect(!coordinator.savedConnections.isEmpty)
        #expect(coordinator.connectionScreen == .pairing(showsSavedConnections: false))
    }

    @Test @MainActor func connectingFallbackToPairingStartsWithoutSavedList() {
        resetConnectionState()
        defer { resetConnectionState() }
        _ = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.currentScreen = .connecting
        coordinator.currentScreen = .pairing
        #expect(coordinator.connectionScreen == .pairing(showsSavedConnections: false))
        #expect(!coordinator.pairingShowsSavedConnections)
    }

    @Test @MainActor func connectionLossOutlivesTheTransportUntilDataReloads() async {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        fake.simulateDisconnect()
        await Self.awaitConnectionScreenTurn()
        guard case .none = coordinator.connectionLoss else {
            Issue.record("A drop before entry must not record a loss")
            return
        }

        fake.simulateConnect()
        await Self.awaitConnectionScreenTurn()
        store.publishFetchedWorkspaces([])
        coordinator.onConnectionSuccess()
        store.setLastUpdated(nil)
        fake.simulateDisconnect()
        await Self.awaitConnectionScreenTurn()
        guard case .lost = coordinator.connectionLoss else {
            Issue.record("Expected .lost, got \(coordinator.connectionLoss)")
            return
        }

        fake.simulateConnect()
        await Self.awaitConnectionScreenTurn()
        guard case .recovering(_, let timeout) = coordinator.connectionLoss else {
            Issue.record("Expected .recovering, got \(coordinator.connectionLoss)")
            return
        }
        #expect(fake.connectionState == .connected)
        #expect(coordinator.isDisconnected)

        fake.simulateDisconnect()
        await Self.awaitConnectionScreenTurn()
        guard case .lost = coordinator.connectionLoss else {
            Issue.record("Expected .lost after a drop during recovery, got \(coordinator.connectionLoss)")
            return
        }
        #expect(timeout.isCancelled)

        coordinator.currentScreen = .connectionFailed(error: "x")
        #expect(!coordinator.isDisconnected)
    }

    @MainActor
    private static func awaitConnectionScreenTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func cancelledConnectIsNeverShownAsAFailure() {
        #expect(ConnectingView.failureOutcome(for: CancellationError(), replacedByNewerAttempt: true) == .leave)
        #expect(ConnectingView.failureOutcome(for: CancellationError(), replacedByNewerAttempt: false) == .retry)
        #expect(ConnectingView.failureOutcome(for: DaemonStartupError.failed, replacedByNewerAttempt: false) == .leave)
        let timedOut = WebSocketTransportError.timedOut(host: "studio")
        #expect(ConnectingView.failureOutcome(for: timedOut, replacedByNewerAttempt: false) == .show(timedOut.localizedDescription))
    }
}
