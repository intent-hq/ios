@testable import Intent
import Testing

/// `followCancelledByGesture`, the claims, and the recovery's
/// continuations and terminal against each state they read.
extension TranscriptRecoveryLifecycleTests {
    // MARK: - followCancelledByGesture

    @Test func gestureCancelsAForcedFollowAndLatchesTheTakeover() {
        var state = makeState(owner: .follow(follow1, forced: true), realized: true)
        let effects = step(&state, .followCancelledByGesture)
        #expect(nonLog(effects) == [.cancelFollowTask(follow1)])
        #expect(logs(effects) == ["[SCROLL] Forced follow cancelled: the user took over"])
        #expect(state.owner == .idle)
    }

    @Test func gestureCancelsAnAutomaticFollowWithoutTheLatchLog() {
        var state = makeState(owner: .follow(follow1, forced: false), realized: true)
        #expect(step(&state, .followCancelledByGesture) == [.cancelFollowTask(follow1)])
        #expect(state.owner == .idle)
    }

    @Test(arguments: [
        ConversationTranscriptRecoveryLifecycle.ArmedRecovery.polling(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2)),
        .demoted(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2))
    ]) func gestureCancelsTheFollowAndTheArmedRecoveryTogether(armed: ConversationTranscriptRecoveryLifecycle.ArmedRecovery) {
        var state = makeState(owner: .follow(follow1, forced: true), armed: armed, realized: false)
        #expect(nonLog(step(&state, .followCancelledByGesture)) == [.cancelFollowTask(follow1), .cancelRecoveryTask(recovery2)])
        #expect(state.owner == .idle)
        #expect(state.armedRecovery == nil)
        #expect(state.currentRecovery == nil)
    }

    @Test func gestureCancelsAnOwningCorrection() {
        var state = makeState(owner: .recovery(recovery1), realized: false)
        #expect(step(&state, .followCancelledByGesture) == [.cancelRecoveryTask(recovery1)])
        #expect(state.owner == .idle)
        #expect(state.armedRecovery == nil)
    }

    @Test func gestureWithNothingPendingChangesNothing() {
        var state = makeState(realized: true)
        let before = state
        #expect(step(&state, .followCancelledByGesture).isEmpty)
        #expect(state == before)
    }

    @Test func gestureDischargesATransferOverAnUnrealizedEndAsGoToEnd() {
        var state = makeState(owner: .follow(follow1, forced: false), armed: .polling(recovery2), fallback: .transferred(follow: follow1), realized: false)
        let effects = step(&state, .followCancelledByGesture)
        #expect(nonLog(effects) == [.cancelFollowTask(follow1), .cancelRecoveryTask(recovery2), .showGoToEnd])
        #expect(state.fallback == .none)
        #expect(state.owner == .idle)
    }

    @Test func gestureDischargesATransferOverARealizedEndSilently() {
        var state = makeState(owner: .follow(follow1, forced: true), fallback: .transferred(follow: follow1), realized: true)
        #expect(nonLog(step(&state, .followCancelledByGesture)) == [.cancelFollowTask(follow1)])
        #expect(state.fallback == .none)
    }

    // MARK: - explicitClaim / viewDisappeared

    @Test(arguments: [ConversationTranscriptRecoveryLifecycle.Event.explicitClaim, .viewDisappeared])
    func claimCancelsTheRecoveryOnly(event: ConversationTranscriptRecoveryLifecycle.Event) {
        var armedUnderFollow = makeState(owner: .follow(follow1, forced: true), armed: .polling(recovery2), fallback: .transferred(follow: follow1))
        #expect(step(&armedUnderFollow, event) == [.cancelRecoveryTask(recovery2)])
        #expect(armedUnderFollow.owner == .follow(follow1, forced: true))
        #expect(armedUnderFollow.fallback == .transferred(follow: follow1))
        #expect(armedUnderFollow.armedRecovery == nil)

        // A demoted recovery is cancelled too: the follow's drain restores
        // nothing.
        var demotedUnderFollow = makeState(owner: .follow(follow1, forced: false), armed: .demoted(recovery2))
        #expect(step(&demotedUnderFollow, event) == [.cancelRecoveryTask(recovery2)])
        #expect(demotedUnderFollow.owner == .follow(follow1, forced: false))
        #expect(demotedUnderFollow.armedRecovery == nil)
        #expect(step(&demotedUnderFollow, .followFinished(follow1, .dropped)) == [.replayLiveEdge(.live)])
        #expect(demotedUnderFollow.owner == .idle)

        var owning = makeState(owner: .recovery(recovery1))
        #expect(step(&owning, event) == [.cancelRecoveryTask(recovery1)])
        #expect(owning.owner == .idle)

        var idle = makeState(owner: .follow(follow1, forced: false))
        let before = idle
        #expect(step(&idle, event).isEmpty)
        #expect(idle == before)
    }

    // MARK: - recoveryStep / recoveryPagedUp

    @Test func settlingStepIsSilent() {
        var armed = makeState(armed: .polling(recovery1))
        let before = armed
        #expect(step(&armed, .recoveryStep(recovery1, .settling)).isEmpty)
        #expect(armed == before)
        var owning = makeState(owner: .recovery(recovery1))
        #expect(step(&owning, .recoveryStep(recovery1, .settling)).isEmpty)
        #expect(owning.owner == .recovery(recovery1))
    }

    @Test func followToEndCorrectionClaimsTheViewport() {
        var state = makeState(armed: .polling(recovery1))
        let effects = step(&state, .recoveryStep(recovery1, .followToEnd))
        #expect(nonLog(effects) == [.scrollToEnd])
        #expect(logs(effects) == ["[SCROLL] End row off screen short of the bottom; following to the end"])
        #expect(state.owner == .recovery(recovery1))
        #expect(state.armedRecovery == nil)
        #expect(state.isFollowing)
        // A second correction keeps the claim.
        #expect(nonLog(step(&state, .recoveryStep(recovery1, .followToEnd))) == [.scrollToEnd])
        #expect(state.owner == .recovery(recovery1))
    }

    @Test func recoverCorrectionClaimsTheViewportAndPagesUp() {
        var state = makeState(armed: .polling(recovery1))
        let effects = step(&state, .recoveryStep(recovery1, .recover(pageOffsetY: 120)))
        #expect(nonLog(effects) == [.pageUp(offsetY: 120)])
        #expect(logs(effects) == ["[SCROLL] Blank viewport at the bottom; paging up and following back"])
        #expect(state.owner == .recovery(recovery1))
        #expect(state.armedRecovery == nil)
    }

    @Test func correctionsAreRefusedWhileAFollowOwns() {
        for continuation in [
            Lifecycle.RecoveryContinuation.followToEnd, .recover(pageOffsetY: 40)
        ] {
            for armed in [Lifecycle.ArmedRecovery.polling(recovery2), .demoted(recovery2)] {
                var state = makeState(owner: .follow(follow1, forced: false), armed: armed)
                let before = state
                #expect(step(&state, .recoveryStep(recovery2, continuation)).isEmpty)
                #expect(state == before)
            }
        }
    }

    @Test func pagedUpCorrectionFollowsBackOnlyWhileItOwns() {
        var owning = makeState(owner: .recovery(recovery1))
        #expect(step(&owning, .recoveryPagedUp(recovery1, mayFollowBack: true)) == [.scrollToEnd])
        #expect(owning.owner == .recovery(recovery1))
        let yielded = step(&owning, .recoveryPagedUp(recovery1, mayFollowBack: false))
        #expect(nonLog(yielded).isEmpty)
        #expect(logs(yielded) == ["[SCROLL] End recovery yielded the paged-up viewport to the user"])
        #expect(owning.owner == .recovery(recovery1))
        // Demoted under a follow requested meanwhile: the token is current
        // but no longer owns, so no follow back is issued over the follow,
        // while its yield is still reported.
        var demoted = makeState(owner: .follow(follow1, forced: true), armed: .demoted(recovery2))
        let before = demoted
        #expect(step(&demoted, .recoveryPagedUp(recovery2, mayFollowBack: true)).isEmpty)
        #expect(demoted == before)
        let demotedYield = step(&demoted, .recoveryPagedUp(recovery2, mayFollowBack: false))
        #expect(nonLog(demotedYield).isEmpty)
        #expect(logs(demotedYield) == ["[SCROLL] End recovery yielded the paged-up viewport to the user"])
        #expect(demoted == before)
        // A stale token neither scrolls nor logs.
        var stale = makeState(owner: .recovery(recovery1))
        let staleBefore = stale
        #expect(step(&stale, .recoveryPagedUp(recovery2, mayFollowBack: true)).isEmpty)
        #expect(step(&stale, .recoveryPagedUp(recovery2, mayFollowBack: false)).isEmpty)
        #expect(stale == staleBefore)
    }

    // MARK: - recoveryFinished

    @Test func giveUpWithNoFollowShowsGoToEnd() {
        var state = makeState(owner: .recovery(recovery1), realized: false)
        let effects = step(&state, .recoveryFinished(recovery1, .giveUp, corrections: 2))
        #expect(nonLog(effects) == [.recordRecoveryOutcome(.giveUp, corrections: 2), .showGoToEnd])
        #expect(logs(effects) == ["[SCROLL] End recovery gave up over an unrealized end row; showing Go to End"])
        #expect(state.owner == .idle)
        #expect(state.fallback == .none)
        #expect(state.currentRecovery == nil)
    }

    @Test(arguments: [
        ConversationTranscriptRecoveryLifecycle.ArmedRecovery.polling(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2)),
        .demoted(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2))
    ]) func giveUpUnderAFollowTransfersToThatFollow(armed: ConversationTranscriptRecoveryLifecycle.ArmedRecovery) {
        var state = makeState(owner: .follow(follow1, forced: false), armed: armed, realized: false)
        let effects = step(&state, .recoveryFinished(recovery2, .giveUp, corrections: 3))
        #expect(effects == [.recordRecoveryOutcome(.giveUp, corrections: 3), .replayLiveEdge(.live)])
        #expect(state.fallback == .transferred(follow: follow1))
        #expect(state.owner == .follow(follow1, forced: false))
        #expect(state.armedRecovery == nil)
    }

    @Test(arguments: [
        ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal.notNeeded, .yieldToUser
    ]) func recoveredAndYieldedDrainsReplayTheLiveEdge(
        terminal: ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal
    ) {
        var owning = makeState(owner: .recovery(recovery1))
        #expect(step(&owning, .recoveryFinished(recovery1, terminal, corrections: 1)) == [
            .recordRecoveryOutcome(terminal, corrections: 1), .replayLiveEdge(.live)
        ])
        #expect(owning.owner == .idle)
        for armed in [Lifecycle.ArmedRecovery.polling(recovery2), .demoted(recovery2)] {
            var underFollow = makeState(owner: .follow(follow1, forced: true), armed: armed)
            #expect(step(&underFollow, .recoveryFinished(recovery2, terminal, corrections: 0)) == [
                .recordRecoveryOutcome(terminal, corrections: 0), .replayLiveEdge(.live)
            ])
            #expect(underFollow.owner == .follow(follow1, forced: true))
            #expect(underFollow.armedRecovery == nil)
        }
    }

    /// The report tells a `noCorrectionNeeded` finish from an episode still
    /// in flight only if the finish is recorded (see
    /// `ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport`).
    @Test func aRecoveryThatCorrectedNothingStillRecordsItsOutcome() {
        var state = makeState(armed: .polling(recovery1), realized: true)
        #expect(step(&state, .recoveryFinished(recovery1, .notNeeded, corrections: 0)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 0), .replayLiveEdge(.live)
        ])
        #expect(state.armedRecovery == nil)
    }
}
