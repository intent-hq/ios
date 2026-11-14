import Foundation
@testable import Intent
import Testing

/// Pins the connection screen and connection-loss states (survey item 7).
extension AppCoordinatorTests {
    @Test @MainActor func connectionScreenKeepsOnlyTheVisibleScreensFields() {
        let launch = ConnectionScreen.connecting(startedByLaunch: true)
        let offer = ConnectionScreen.pairing(showsSavedConnections: true)
        // The splash spans loading and connecting, so launch survives that step.
        #expect(launch.kept(on: .loading) == launch)
        #expect(launch.kept(on: .connecting) == launch)
        #expect(offer.kept(on: .pairing) == offer)
        // Entering a connection screen without an explicit value starts off.
        #expect(offer.kept(on: .connecting) == .connecting(startedByLaunch: false))
        #expect(ConnectionScreen.other.kept(on: .loading) == .connecting(startedByLaunch: false))
        #expect(launch.kept(on: .pairing) == .pairing(showsSavedConnections: false))
        // Every other screen carries neither field.
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

        // Every route back to Connecting is user-started and shows Back.
        coordinator.restartConnectionAttempt()
        #expect(coordinator.connectionScreen == .connecting(startedByLaunch: false))
    }

    /// Deliberate: Connect to… reached without a fresh saved-connection read
    /// starts without the saved list. On `main` a value left from an earlier
    /// visit to Connect to… could still offer it.
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

        // Re-pairing the same Mac restarts its attempt, which then fails.
        coordinator.onPaired(stored)
        #expect(coordinator.connectionScreen == .connecting(startedByLaunch: false))
        coordinator.onConnectionFailed(error: "timeout")
        #expect(coordinator.connectionScreen == .other)

        // An unreadable store keeps the old snapshot but cannot refresh the offer.
        #expect(persistence.saveDataToKeychain(
            data: Data("{\"v\": 99, \"schema\": \"future\"}".utf8),
            account: persistence.keychainAccountConnections
        ))
        coordinator.onReconnect()
        #expect(!coordinator.savedConnections.isEmpty)
        #expect(coordinator.connectionScreen == .pairing(showsSavedConnections: false))
    }

    /// ConnectingView's fallback for a window with no saved Mac matches `main`:
    /// that path never had the saved list turned on.
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

        // Before entry, a drop is not a loss: the startup screens own it.
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

        // Reconnected but still waiting for data: the overlay stays.
        fake.simulateConnect()
        await Self.awaitConnectionScreenTurn()
        guard case .recovering(_, let timeout) = coordinator.connectionLoss else {
            Issue.record("Expected .recovering, got \(coordinator.connectionLoss)")
            return
        }
        #expect(fake.connectionState == .connected)
        #expect(coordinator.isDisconnected)

        // Dropping again during recovery shows the loss and retires the timeout.
        fake.simulateDisconnect()
        await Self.awaitConnectionScreenTurn()
        guard case .lost = coordinator.connectionLoss else {
            Issue.record("Expected .lost after a drop during recovery, got \(coordinator.connectionLoss)")
            return
        }
        #expect(timeout.isCancelled)

        // Leaving the remote UI clears the loss whatever the transport says.
        coordinator.currentScreen = .connectionFailed(error: "x")
        #expect(!coordinator.isDisconnected)
    }

    @MainActor
    private static func awaitConnectionScreenTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func supersededConnectIsNotShownAsAFailure() {
        // A newer connect on the same session (e.g. a pairing link moving
        // this window to another host) cancels the older one; its
        // cancellation must not show "Swift.CancellationError" as a failure.
        #expect(ConnectingView.failureMessage(for: CancellationError()) == nil)
        #expect(ConnectingView.failureMessage(for: DaemonStartupError.failed) == nil)
        let timedOut = WebSocketTransportError.timedOut(host: "studio")
        #expect(ConnectingView.failureMessage(for: timedOut) == timedOut.localizedDescription)
    }
}
