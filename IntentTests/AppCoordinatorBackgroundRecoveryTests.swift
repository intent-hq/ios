import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func hiddenOverlayDoesNotEnableComposerSends() async {
        let fixture = await backgroundRecoveryFixture()
        let viewModel = ConversationViewModel(
            agentId: "background-agent",
            workspaceId: "background-workspace",
            agentName: "Agent",
            connection: fixture.connection,
            uploadService: .shared,
            optionsStore: CreationOptionsStore()
        )
        let composer = MessageInputView(viewModel: viewModel, store: viewModel.store)
        #expect(composer.isConnectionReadyForSending)
        fixture.coordinator.onScenePhaseBackground()
        fixture.coordinator.onScenePhaseActive()
        for state in [ConnectionState.disconnected, .reconnecting(attempt: 1), .connecting] {
            fixture.connection.connectionState = state
            #expect(!composer.isConnectionReadyForSending, "Block even before the queued loss notification arrives")
            await Self.drainBackgroundEvents()
            #expect(!fixture.coordinator.showsConnectionLossOverlay)
        }
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        #expect(composer.isConnectionReadyForSending)
        fixture.clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
    }

    @Test @MainActor func backgroundLossStaysHiddenAndQuickRecoveryCancelsDeadline() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseBackground()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        #expect(coordinator.isDisconnected, "Presentation grace must not pretend the transport recovered")
        #expect(!coordinator.showsConnectionLossOverlay)
        #expect(fixture.clock.deadlines.isEmpty, "No timer runs while backgrounded")

        coordinator.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        fixture.clock.advance(by: .milliseconds(999))
        #expect(!coordinator.showsConnectionLossOverlay)
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        #expect(!coordinator.isDisconnected)
        #expect(!coordinator.connectionLossPresentation.isDeferred)
        fixture.clock.advance(by: .milliseconds(1))
        await Self.drainBackgroundEvents()
        #expect(!coordinator.showsConnectionLossOverlay)
        #expect(fixture.clock.cancelledSleeps == 1)
    }

    /// A recovery that first waits for workspace data (`.recovering` → `.none`)
    /// must still retire the background grace, like an immediate recovery.
    @Test @MainActor func recoveryAfterWorkspaceReloadRetiresBackgroundGrace() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseBackground()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        coordinator.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        #expect(coordinator.connectionLossPresentation.isDeferred)

        fixture.store.setLastUpdated(nil) // Recovery must wait for a fresh snapshot.
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        guard case .recovering = coordinator.connectionLoss else {
            Issue.record("Expected .recovering, got \(coordinator.connectionLoss)")
            return
        }
        #expect(coordinator.connectionLossPresentation.isDeferred, "Grace lasts while data reloads")

        fixture.store.setLoading(true)
        await Self.drainBackgroundEvents()
        fixture.store.setLoading(false)
        await Self.drainBackgroundEvents()
        #expect(!coordinator.isDisconnected)
        #expect(!coordinator.connectionLossPresentation.isDeferred, "recovered() must reset the grace")
        fixture.clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
        #expect(fixture.clock.cancelledSleeps == 1, "The grace deadline was retired, not reached")
        #expect(!coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func sustainedBackgroundLossAppearsAtOneSecondWithoutExtendingDeadline() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseBackground()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        let returnTime = fixture.clock.now
        coordinator.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        #expect(fixture.clock.deadlines == [returnTime + .seconds(1)])
        fixture.clock.advance(by: .milliseconds(999))
        fixture.connection.connectionState = .reconnecting(attempt: 2)
        coordinator.onScenePhaseActive() // Duplicate active must not extend the deadline.
        await Self.drainBackgroundEvents()
        #expect(!coordinator.showsReadOnlyBanner)
        #expect(coordinator.isRemoteReadOnly, "Change controls stay off during the grace")
        #expect(fixture.clock.deadlines.count == 1)
        fixture.clock.advance(by: .milliseconds(1))
        await Self.drainBackgroundEvents()
        #expect(coordinator.showsReadOnlyBanner, "A drop that keeps reconnecting is read-only, not blocking")
        #expect(!coordinator.showsConnectionLossOverlay)
        #expect(fixture.connection.connectionState == .reconnecting(attempt: 2))
    }

    @Test @MainActor func backgroundReturnProtectsLossQueuedBeforeOrAfterActivation() async {
        for lossBeforeActivation in [true, false] {
            let fixture = await backgroundRecoveryFixture()
            let coordinator = fixture.coordinator
            coordinator.onScenePhaseBackground()
            if lossBeforeActivation { fixture.connection.simulateStoppedReconnection() }
            coordinator.onScenePhaseActive()
            if !lossBeforeActivation { fixture.connection.simulateStoppedReconnection() }
            await Self.drainBackgroundEvents()
            #expect(coordinator.isDisconnected)
            #expect(!coordinator.showsConnectionLossOverlay)
            fixture.connection.simulateConnect()
            await Self.drainBackgroundEvents()
            fixture.clock.advance(by: .seconds(1))
            await Self.drainBackgroundEvents()
            #expect(!coordinator.showsConnectionLossOverlay)
        }
    }

    @Test @MainActor func backgroundRecoveryBeforeActivationStillProtectsNewQueuedLoss() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseBackground()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        #expect(!coordinator.isDisconnected)
        coordinator.onScenePhaseActive()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        #expect(!coordinator.showsConnectionLossOverlay)
        fixture.clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
        #expect(coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func lossAfterHealthyGraceExpiresIsImmediate() async {
        let fixture = await backgroundRecoveryFixture()
        fixture.coordinator.onScenePhaseBackground()
        fixture.coordinator.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        fixture.clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        #expect(fixture.coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func queuedObsoleteLossCannotReappearAfterRecovery() async {
        let fixture = await backgroundRecoveryFixture()
        fixture.coordinator.onScenePhaseBackground()
        fixture.coordinator.onScenePhaseActive()
        fixture.clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
        // Both deliveries are queued; the loss is obsolete before it is read.
        fixture.connection.simulateStoppedReconnection()
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        #expect(!fixture.coordinator.isDisconnected)
        #expect(!fixture.coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func recoveryStillWaitsForWorkspaceReadinessRatherThanNetworkAvailability() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseBackground()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        fixture.store.setLoading(true)
        fixture.store.setLastUpdated(nil)
        coordinator.onScenePhaseActive()
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        #expect(coordinator.isDisconnected)
        #expect(!coordinator.showsReadOnlyBanner)
        fixture.clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
        #expect(coordinator.showsReadOnlyBanner, "The existing data-readiness rule still applies")
        #expect(!coordinator.showsConnectionLossOverlay)
        fixture.store.publishFetchedWorkspaces([])
        fixture.store.setLoading(false)
        await Self.drainBackgroundEvents()
        #expect(!coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func existingVisibleLossAndInactiveOnlyTransitionsNeverGetGrace() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseNotActive()
        coordinator.onScenePhaseActive()
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        #expect(coordinator.showsConnectionLossOverlay)
        coordinator.onScenePhaseBackground()
        #expect(coordinator.showsConnectionLossOverlay)
        coordinator.onScenePhaseActive()
        #expect(coordinator.showsConnectionLossOverlay)
        #expect(fixture.clock.deadlines.isEmpty)
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        #expect(!coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func staleWorkspaceCompletionCannotEndGraceDuringRenewedLoss() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseBackground()
        fixture.connection.simulateStoppedReconnection()
        coordinator.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        fixture.store.setLastUpdated(nil)
        fixture.store.setLoading(true)
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        // Queue data completion ahead of a new loss delivery. The current
        // transport state must win even when the old observation runs first.
        fixture.store.setLoading(false)
        fixture.connection.simulateStoppedReconnection()
        await Self.drainBackgroundEvents()
        #expect(coordinator.isDisconnected)
        #expect(!coordinator.showsConnectionLossOverlay)
        fixture.clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
        #expect(coordinator.showsConnectionLossOverlay)
    }

    @Test @MainActor func coldLaunchAndUnusableStartupCannotArmBackgroundGrace() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        let screens: [AppScreen] = [.loading, .connecting, .pairing, .connectionFailed(error: "certificate"), .workspaceList]
        for screen in screens {
            coordinator.currentScreen = screen
            coordinator.onScenePhaseBackground()
            coordinator.onScenePhaseActive()
            #expect(!coordinator.connectionLossPresentation.isDeferred)
        }
        #expect(fixture.clock.deadlines.isEmpty)
    }

    @Test @MainActor func repeatedBackgroundCycleInvalidatesOldDeadline() async {
        let fixture = await backgroundRecoveryFixture()
        let coordinator = fixture.coordinator
        coordinator.onScenePhaseBackground()
        fixture.connection.simulateStoppedReconnection()
        coordinator.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        fixture.clock.advance(by: .milliseconds(500))
        coordinator.onScenePhaseBackground()
        fixture.clock.advance(by: .milliseconds(500))
        await Self.drainBackgroundEvents()
        #expect(!coordinator.showsConnectionLossOverlay, "The first cancelled deadline cannot present in background")
        coordinator.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        fixture.clock.advance(by: .milliseconds(999))
        await Self.drainBackgroundEvents()
        #expect(!coordinator.showsConnectionLossOverlay)
        fixture.clock.advance(by: .milliseconds(1))
        await Self.drainBackgroundEvents()
        #expect(coordinator.showsConnectionLossOverlay)
        #expect(fixture.clock.cancelledSleeps == 1)
    }

    @Test @MainActor func leavingSessionInvalidatesPendingBackgroundPresentation() async {
        for action in ["home", "switch", "logoff", "certificate"] {
            let fixture = await backgroundRecoveryFixture()
            let coordinator = fixture.coordinator
            coordinator.onScenePhaseBackground()
            fixture.connection.simulateStoppedReconnection()
            coordinator.onScenePhaseActive()
            await Self.drainBackgroundEvents()
            switch action {
            case "home": coordinator.onReturnToSavedMachines()
            case "switch": coordinator.onSwitchConnection(id: UUID())
            case "logoff": #expect(coordinator.onLogOff())
            default: coordinator.onConnectionFailed(error: "certificate changed")
            }
            fixture.connection.simulateConnect()
            fixture.clock.advance(by: .seconds(1))
            await Self.drainBackgroundEvents()
            #expect(!coordinator.showsConnectionLossOverlay)
            #expect(!coordinator.connectionLossPresentation.isDeferred)
            #expect(fixture.clock.cancelledSleeps == 1)
        }
    }

    @Test @MainActor func coordinatorDisposalCancelsBackgroundDeadlineWithoutRetainingCoordinator() async {
        let clock = BackgroundPresentationClock()
        let presentation = ConnectionLossPresentation(now: { clock.now }, sleepUntil: clock.sleep)
        var coordinator: AppCoordinator? = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            persistence: persistence,
            connectionLossPresentation: presentation
        )
        weak var weakCoordinator = coordinator
        coordinator?.lifecycleState.entry = .entered
        coordinator?.onScenePhaseBackground()
        coordinator?.onScenePhaseActive()
        await Self.drainBackgroundEvents()
        coordinator = nil
        #expect(weakCoordinator == nil)
        #expect(!presentation.isDeferred)
        clock.advance(by: .seconds(1))
        await Self.drainBackgroundEvents()
        #expect(clock.cancelledSleeps == 1)
    }

    @MainActor private func backgroundRecoveryFixture() async -> BackgroundRecoveryFixture {
        let fixture = BackgroundRecoveryFixture(persistence: persistence)
        fixture.connection.simulateConnect()
        await Self.drainBackgroundEvents()
        fixture.store.publishFetchedWorkspaces([])
        fixture.coordinator.onConnectionSuccess()
        await Self.drainBackgroundEvents()
        #expect(fixture.coordinator.lifecycleState.hasEnteredRemoteUI)
        return fixture
    }

    @MainActor private static func drainBackgroundEvents() async {
        let queueTurns = 3
        for _ in 0..<queueTurns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor private struct BackgroundRecoveryFixture {
    let clock = BackgroundPresentationClock()
    let connection = FakeConnectionManager()
    let store = WorkspaceStore(forTesting: true)
    let coordinator: AppCoordinator

    init(persistence: PersistenceManager) {
        let clock = clock
        coordinator = AppCoordinator(
            workspaceStore: store,
            connection: connection,
            persistence: persistence,
            connectionLossPresentation: ConnectionLossPresentation(now: { clock.now }, sleepUntil: clock.sleep)
        )
    }
}

/// Deliberately resumes even cancelled sleeps: tests exercise generation and
/// cancellation guards, not a fake that silently discards stale callbacks.
@MainActor private final class BackgroundPresentationClock {
    var now = ContinuousClock.now
    var deadlines: [ContinuousClock.Instant] = []
    var cancelledSleeps = 0
    private var sleepers: [(ContinuousClock.Instant, CheckedContinuation<Void, Never>)] = []

    func sleep(until deadline: ContinuousClock.Instant) async {
        deadlines.append(deadline)
        if deadline > now {
            await withCheckedContinuation { sleepers.append((deadline, $0)) }
        }
        if Task.isCancelled { cancelledSleeps += 1 }
    }

    func advance(by duration: Duration) {
        now += duration
        let ready = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        for (_, continuation) in ready { continuation.resume() }
    }
}
