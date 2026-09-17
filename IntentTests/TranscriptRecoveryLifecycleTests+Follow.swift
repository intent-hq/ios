import CoreGraphics
@testable import Intent
import Testing

/// `followRequested`, `followDue` and `followFinished` against each
/// owner / fallback state they read.
extension TranscriptRecoveryLifecycleTests {
    // MARK: - followRequested

    @Test(arguments: [false, true]) func followRequestedFromIdleStartsAFollow(forced: Bool) {
        var state = State()
        #expect(step(&state, .followRequested(forced: forced)) == [.startFollowTask(follow1, forced: forced)])
        #expect(state.owner == .follow(follow1, forced: forced))
        #expect(state.isFollowing)
        #expect(state.nextTokenId == 2)
    }

    @Test func automaticFollowNeverPreemptsAForcedOne() {
        var state = makeState(owner: .follow(follow1, forced: true), armed: .polling(recovery2))
        let before = state
        #expect(step(&state, .followRequested(forced: false)).isEmpty)
        #expect(state == before)
    }

    @Test(arguments: [(false, false), (false, true), (true, true)])
    func followReplacesThePendingFollow(current: Bool, requested: Bool) {
        var state = makeState(owner: .follow(follow1, forced: current))
        let replacement = FollowToken(id: 3)
        #expect(step(&state, .followRequested(forced: requested)) == [
            .cancelFollowTask(follow1), .startFollowTask(replacement, forced: requested)
        ])
        #expect(state.owner == .follow(replacement, forced: requested))
        #expect(state.fallback == .none)
    }

    @Test func replacingFollowInheritsTheTransferredGiveUp() {
        var state = makeState(owner: .follow(follow1, forced: false), fallback: .transferred(follow: follow1))
        let replacement = FollowToken(id: 3)
        step(&state, .followRequested(forced: true))
        #expect(state.fallback == .transferred(follow: replacement))
        // The replaced follow's terminal is stale and cannot discharge it.
        #expect(step(&state, .followFinished(follow1, .dropped)).isEmpty)
        #expect(state.fallback == .transferred(follow: replacement))
        // The replacement's does, exactly once.
        #expect(step(&state, .followFinished(replacement, .yielded)).contains(.showGoToEnd))
        #expect(state.fallback == .none)
    }

    @Test func followRequestedDemotesAnOwningRecoveryToArmed() {
        var state = makeState(owner: .recovery(recovery1))
        let follow = FollowToken(id: 3)
        #expect(step(&state, .followRequested(forced: false)) == [.startFollowTask(follow, forced: false)])
        #expect(state.owner == .follow(follow, forced: false))
        #expect(state.armedRecovery == .demoted(recovery1))
        #expect(state.currentRecovery == recovery1)
    }

    @Test func followRequestedKeepsAnArmedRecovery() {
        var state = makeState(armed: .polling(recovery1))
        step(&state, .followRequested(forced: true))
        #expect(state.armedRecovery == .polling(recovery1))
        #expect(state.owner == .follow(FollowToken(id: 3), forced: true))
    }

    @Test func aReplacingFollowKeepsTheDemotedRecoveryForItsOwnDrain() {
        var state = makeState(owner: .follow(follow1, forced: false), armed: .demoted(recovery2))
        let replacement = FollowToken(id: 3)
        step(&state, .followRequested(forced: true))
        #expect(state.owner == .follow(replacement, forced: true))
        #expect(state.armedRecovery == .demoted(recovery2))
        #expect(step(&state, .followFinished(follow1, .replaced)).isEmpty)
        #expect(state.armedRecovery == .demoted(recovery2))
        #expect(step(&state, .followFinished(replacement, .cancelled)).isEmpty)
        #expect(state.owner == .recovery(recovery2))
        #expect(state.armedRecovery == nil)
    }

    // MARK: - followDue

    @Test(arguments: [false, true]) func followDueThatExecutesScrollsToEnd(forced: Bool) {
        var state = makeState(owner: .follow(follow1, forced: forced), armed: .polling(recovery2))
        let before = state
        #expect(step(&state, .followDue(follow1, execute: true)) == [.scrollToEnd])
        #expect(state == before)
    }

    @Test func droppedAutomaticFollowIsSilentWhenDue() {
        var state = makeState(owner: .follow(follow1, forced: false))
        #expect(step(&state, .followDue(follow1, execute: false)).isEmpty)
        #expect(state.owner == .follow(follow1, forced: false))
    }

    @Test func yieldedForcedFollowReplaysTheLiveEdgeAsTheGestureSample() {
        var state = makeState(owner: .follow(follow1, forced: true))
        let effects = step(&state, .followDue(follow1, execute: false))
        #expect(nonLog(effects) == [.replayLiveEdge(.sampled(isInteracting: true))])
        #expect(logs(effects) == ["[SCROLL] Forced follow yielded to the user's gesture"])
        #expect(state.owner == .follow(follow1, forced: true))
    }

    // MARK: - followFinished

    @Test func executedAutomaticFollowReplaysTheEdgeItSwallowed() {
        var state = makeState(owner: .follow(follow1, forced: false), realized: true)
        #expect(step(&state, .followFinished(follow1, .executed(nil))) == [.replayLiveEdge(.live)])
        #expect(state.owner == .idle)
        #expect(!state.isFollowing)
    }

    @Test func executedForcedFollowReplaysNothing() {
        var state = makeState(owner: .follow(follow1, forced: true), realized: true)
        #expect(step(&state, .followFinished(follow1, .executed(.landed))).isEmpty)
        #expect(state.owner == .idle)
    }

    @Test func executedFollowOverAnUnrealizedEndReArmsTheRecovery() {
        var state = makeState(owner: .follow(follow1, forced: true), realized: false)
        #expect(step(&state, .followFinished(follow1, .executed(.giveUp))) == [.startRecoveryTask(RecoveryToken(id: 3))])
        #expect(state.armedRecovery == .polling(RecoveryToken(id: 3)))
        #expect(state.owner == .idle)
    }

    @Test func executedFollowDoesNotDoubleArmARecoveryAlreadyPolling() {
        var state = makeState(owner: .follow(follow1, forced: false), armed: .polling(recovery2), realized: false)
        #expect(step(&state, .followFinished(follow1, .executed(nil))) == [.replayLiveEdge(.live)])
        #expect(state.armedRecovery == .polling(recovery2))
        #expect(state.nextTokenId == 3)
    }

    @Test func executedFollowOverAnUnrealizedEndRestoresADemotedRecoveryInsteadOfReArming() {
        var state = makeState(owner: .follow(follow1, forced: false), armed: .demoted(recovery2), realized: false)
        #expect(step(&state, .followFinished(follow1, .executed(.giveUp))) == [.replayLiveEdge(.live)])
        #expect(state.owner == .recovery(recovery2))
        #expect(state.armedRecovery == nil)
        #expect(state.nextTokenId == 3)
    }

    /// The verifier's repro of the shipped view's order at a drain: a
    /// message appended mid-correction requests an automatic follow whose
    /// debounce (100 ms) elapses before the page up settles (150 ms) and is
    /// dropped on the paged-up distance; the view keeps
    /// `isRecoveringUnrealizedEnd` raised, so the drain's replayed edge sees
    /// `isFollowing` and the page-up check then follows back.
    @Test func aDrainedFollowRestoresTheRecoveryItDemoted() {
        var state = State()
        step(&state, .endDerealized)
        #expect(nonLog(step(&state, .recoveryStep(recovery1, .recover(pageOffsetY: 120)))) == [.pageUp(offsetY: 120)])
        #expect(state.owner == .recovery(recovery1))
        #expect(step(&state, .followRequested(forced: false)) == [.startFollowTask(follow2, forced: false)])
        #expect(state.owner == .follow(follow2, forced: false))
        #expect(state.armedRecovery == .demoted(recovery1))
        #expect(state.isFollowing)
        #expect(step(&state, .followDue(follow2, execute: false)).isEmpty)
        // The drain replays the swallowed edge with the recovery owning
        // again: `isFollowing` still reads true for that replay, no re-arm.
        #expect(step(&state, .followFinished(follow2, .dropped)) == [.replayLiveEdge(.live)])
        #expect(state.owner == .recovery(recovery1))
        #expect(state.armedRecovery == nil)
        #expect(state.isFollowing)
        #expect(state.currentRecovery == recovery1)
        // Then the settled page up is granted its follow back.
        #expect(step(&state, .recoveryPagedUp(recovery1, mayFollowBack: true)) == [.scrollToEnd])
        #expect(state.owner == .recovery(recovery1))
        #expect(step(&state, .recoveryFinished(recovery1, .notNeeded, corrections: 1)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 1), .replayLiveEdge(.live)
        ])
        #expect(state.owner == .idle)
        #expect(!state.isFollowing)
    }

    /// Correcting recovery → follow → drain → geometry edge: the geometry
    /// paths read `isFollowing` from the restored owner until the recovery's
    /// own terminal, where a never-claimed polling recovery leaves it false.
    @Test func aRestoredRecoveryKeepsIsFollowingForTheGeometryEdgeUntilItsTerminal() {
        var corrected = State()
        step(&corrected, .endDerealized)
        step(&corrected, .recoveryStep(recovery1, .followToEnd))
        step(&corrected, .followRequested(forced: true))
        step(&corrected, .followDue(follow2, execute: false))
        #expect(step(&corrected, .followFinished(follow2, .yielded)).isEmpty)
        #expect(corrected.owner == .recovery(recovery1))
        #expect(corrected.isFollowing)
        #expect(step(&corrected, .endRealized(userIsScrolledAway: true)) == [.replayLiveEdge(.live)])
        #expect(corrected.isFollowing)
        #expect(step(&corrected, .recoveryFinished(recovery1, .notNeeded, corrections: 1)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 1), .replayLiveEdge(.live)
        ])
        #expect(!corrected.isFollowing)

        var polling = State()
        step(&polling, .endDerealized)
        step(&polling, .followRequested(forced: true))
        step(&polling, .followDue(follow2, execute: false))
        #expect(step(&polling, .followFinished(follow2, .yielded)).isEmpty)
        #expect(polling.owner == .idle)
        #expect(polling.armedRecovery == .polling(recovery1))
        #expect(!polling.isFollowing)
    }

    @Test func executedFollowDischargesATransferWithNoGoToEndAndReArms() {
        var state = makeState(owner: .follow(follow1, forced: true), fallback: .transferred(follow: follow1), realized: false)
        let effects = step(&state, .followFinished(follow1, .executed(.landed)))
        #expect(effects == [.startRecoveryTask(RecoveryToken(id: 3))])
        #expect(state.fallback == .none)
    }

    @Test(arguments: [
        ConversationTranscriptScrollPolicy.FollowTerminal.dropped, .yielded, .cancelled, .replaced
    ]) func unexecutedFollowWithATransferOverAnUnrealizedEndShowsGoToEnd(
        terminal: ConversationTranscriptScrollPolicy.FollowTerminal
    ) {
        for forced in [false, true] {
            var state = makeState(owner: .follow(follow1, forced: forced), fallback: .transferred(follow: follow1), realized: false)
            let effects = step(&state, .followFinished(follow1, terminal))
            #expect(nonLog(effects) == [.showGoToEnd])
            #expect(logs(effects) == [
                "[SCROLL] End recovery gave up and the follow it deferred to did not execute; showing Go to End"
            ])
            #expect(state.fallback == .none)
            #expect(state.owner == .idle)
            #expect(state.armedRecovery == nil)
        }
    }

    @Test func unexecutedFollowWithATransferOverARealizedEndClearsItSilently() {
        var auto = makeState(owner: .follow(follow1, forced: false), fallback: .transferred(follow: follow1), realized: true)
        #expect(step(&auto, .followFinished(follow1, .dropped)) == [.replayLiveEdge(.live)])
        #expect(auto.fallback == .none)
        var forced = makeState(owner: .follow(follow1, forced: true), fallback: .transferred(follow: follow1), realized: true)
        #expect(step(&forced, .followFinished(follow1, .yielded)).isEmpty)
        #expect(forced.fallback == .none)
    }

    @Test func droppedAutomaticFollowWithoutATransferReplaysTheLiveEdge() {
        var state = makeState(owner: .follow(follow1, forced: false), armed: .polling(recovery2), realized: false)
        #expect(step(&state, .followFinished(follow1, .dropped)) == [.replayLiveEdge(.live)])
        #expect(state.armedRecovery == .polling(recovery2))
        #expect(state.owner == .idle)
    }

    @Test func yieldedForcedFollowWithoutATransferDrainsSilently() {
        var state = makeState(owner: .follow(follow1, forced: true), realized: false)
        #expect(step(&state, .followFinished(follow1, .yielded)).isEmpty)
        #expect(state.owner == .idle)
        #expect(state.armedRecovery == nil)
    }

    @Test func aTransferIsDischargedExactlyOnce() {
        var state = makeState(owner: .follow(follow1, forced: false), fallback: .transferred(follow: follow1), realized: false)
        #expect(step(&state, .followFinished(follow1, .dropped)).contains(.showGoToEnd))
        let after = state
        #expect(step(&state, .followFinished(follow1, .dropped)).isEmpty)
        #expect(step(&state, .followCancelledByGesture).isEmpty)
        #expect(state == after)
    }
}
