import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func reconnectingAfterEntryIsReadOnlyWithoutBlockingOverlay() async {
        let fixture = await readOnlyFixture()
        fixture.connection.connectionState = .reconnecting(attempt: 1)
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.remotePhase == .readOnly)
        #expect(fixture.coordinator.isRemoteReadOnly)
        #expect(fixture.coordinator.showsReadOnlyBanner)
        #expect(!fixture.coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func stoppedReconnectionBlocksWithReasonAndNoBanner() async {
        let fixture = await readOnlyFixture()
        fixture.connection.connectionState = .reconnecting(attempt: 1)
        await Self.drainReadOnlyEvents()
        fixture.connection.reconnectStopReason = "This connection belongs to a different person."
        fixture.connection.connectionState = .disconnected
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.remotePhase == .stopped)
        #expect(fixture.coordinator.isRemoteReadOnly)
        #expect(fixture.coordinator.showsConnectionLossOverlay)
        #expect(!fixture.coordinator.showsReadOnlyBanner)
    }

    @Test @MainActor func recoveryClearsReadOnlyAfterWorkspaceReload() async {
        let fixture = await readOnlyFixture()
        fixture.connection.connectionState = .reconnecting(attempt: 1)
        await Self.drainReadOnlyEvents()
        fixture.connection.simulateConnect()
        await Self.drainReadOnlyEvents()
        fixture.store.publishFetchedWorkspaces([])
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.remotePhase == .live)
        #expect(!fixture.coordinator.isRemoteReadOnly)
        #expect(!fixture.coordinator.showsReadOnlyBanner)
    }

    @Test @MainActor func lossBeforeEnteringRemoteUIIsNotReadOnly() async {
        let fixture = ReadOnlyFixture(persistence: persistence)
        fixture.connection.connectionState = .reconnecting(attempt: 1)
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.remotePhase == .live)
        #expect(!fixture.coordinator.showsReadOnlyBanner)
    }

    @Test @MainActor func presentedBannerStaysAcrossBackgroundReturn() async {
        let fixture = await readOnlyFixture()
        fixture.connection.connectionState = .reconnecting(attempt: 1)
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.showsReadOnlyBanner)
        fixture.coordinator.onScenePhaseBackground()
        #expect(fixture.coordinator.showsReadOnlyBanner, "A shown banner must not hide while backgrounded")
        fixture.coordinator.onScenePhaseActive()
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.showsReadOnlyBanner, "Nor flash off on return")
    }

    @Test @MainActor func assistantStaysReachableWhileReadOnly() async {
        let fixture = await readOnlyFixture()
        fixture.connection.connectionState = .reconnecting(attempt: 1)
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.canUseAssistant, "Reading recent Assistant chats is navigation, not a change")
        #expect(!fixture.coordinator.canCreateWorkspace)
    }

    @Test @MainActor func returnHomeClearsReadOnly() async {
        let fixture = await readOnlyFixture()
        fixture.connection.connectionState = .reconnecting(attempt: 1)
        await Self.drainReadOnlyEvents()
        fixture.coordinator.onReturnToSavedMachines()
        #expect(fixture.coordinator.remotePhase == .live)
        #expect(!fixture.coordinator.showsReadOnlyBanner)
    }

    @MainActor private func readOnlyFixture() async -> ReadOnlyFixture {
        let fixture = ReadOnlyFixture(persistence: persistence)
        fixture.connection.simulateConnect()
        await Self.drainReadOnlyEvents()
        fixture.store.publishFetchedWorkspaces([])
        fixture.coordinator.onConnectionSuccess()
        await Self.drainReadOnlyEvents()
        #expect(fixture.coordinator.lifecycleState.hasEnteredRemoteUI)
        return fixture
    }

    @MainActor private static func drainReadOnlyEvents() async {
        let queueTurns = 3
        for _ in 0..<queueTurns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor private struct ReadOnlyFixture {
    let connection = FakeConnectionManager()
    let store = WorkspaceStore(forTesting: true)
    let coordinator: AppCoordinator

    init(persistence: PersistenceManager) {
        coordinator = AppCoordinator(workspaceStore: store, connection: connection, persistence: persistence)
    }
}
