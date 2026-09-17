import CoreGraphics
@testable import Intent
import Testing

/// The #350 handoff defects (scenarios 1-4) replayed as event sequences
/// through `LifecycleHarness`.
extension TranscriptRecoveryLifecycleTests {
    /// Scenario 1 (14927b8): a correction pages up and the finger lands
    /// during the settle. The takeover cancels the recovery; the settle's
    /// continuation and terminal are stale, granted or not, so nothing
    /// scrolls the user back and the recovery shows no Go to End — the flag
    /// raised is the gesture's own edge.
    @Test func aPageUpTakenOverByAGestureDuringTheSettleIsStale() {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.isLive(recovery1))
        #expect(harness.poll(blank) == .continue(.recover(pageOffsetY: 1600)))
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        #expect(harness.state.owner == .recovery(recovery1))
        #expect(harness.pageUps == [1600])
        #expect(harness.gestureBegins(distanceToBottom: 700) == [.cancelRecoveryTask(recovery1)])
        #expect(harness.state.owner == .idle)
        #expect(harness.state.currentRecovery == nil)
        #expect(!harness.isLive(recovery1))
        #expect(harness.userIsScrolledAway)
        #expect(harness.goToEndShown == 0)
        #expect(!harness.mayFollowBack())
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: false)).isEmpty)
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: true)).isEmpty)
        #expect(harness.send(.recoveryFinished(recovery1, .yieldToUser, corrections: 1)).isEmpty)
        #expect(harness.scrolls == 0)
        #expect(harness.rePins == 0)
        #expect(harness.outcomes.isEmpty)
        #expect(harness.goToEndShown == 0)
        #expect(harness.state.owner == .idle)
    }

    /// Scenario 2 (e3cd988): a message appended mid-correction requests an
    /// automatic follow; the recovery's budget is spent under it, so the
    /// give-up is transferred to that follow; content grows during the
    /// debounce and the follow comes due 120pt short with no gesture —
    /// dropped. Its drain shows Go to End over the still-unrealized row,
    /// re-pins nothing over the button and arms nothing; the transfer is
    /// discharged exactly once. Without the transfer the drain would have
    /// replayed the edge as a raw re-pin with the button hidden.
    @Test func aGiveUpUnderAPendingAutomaticFollowIsShownWhenThatFollowIsDropped() {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.poll(geometry(offsetY: 260)) == .continue(.followToEnd))
        #expect(harness.send(.recoveryStep(recovery1, .followToEnd)) == [LogLine.followToEnd, .scrollToEnd])
        #expect(harness.scrolls == 1)
        #expect(harness.send(.followRequested(forced: false)) == [.startFollowTask(follow2, forced: false)])
        #expect(harness.state.owner == .follow(follow2, forced: false))
        #expect(harness.state.armedRecovery == .demoted(recovery1))
        #expect(harness.poll(geometry(offsetY: 260), correctionsSpent: 1) == .continue(.settling))
        #expect(harness.send(.recoveryStep(recovery1, .settling)).isEmpty)
        #expect(harness.poll(geometry(offsetY: 260), correctionsSpent: 1, timedOut: true) == .finish(.giveUp))
        harness.distanceToBottom = 40
        #expect(harness.send(.recoveryFinished(recovery1, .giveUp, corrections: 1)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 1), .replayLiveEdge(.live)
        ])
        #expect(harness.state.fallback == .transferred(follow: follow2))
        #expect(harness.state.armedRecovery == nil)
        #expect(harness.state.owner == .follow(follow2, forced: false))
        #expect(!harness.isLive(recovery1))
        #expect(harness.isLive(follow2))
        #expect(!harness.userIsScrolledAway)
        #expect(harness.rePins == 0)
        harness.distanceToBottom = 120
        #expect(!harness.execute())
        #expect(harness.send(.followDue(follow2, execute: false)).isEmpty)
        #expect(harness.send(.followFinished(follow2, .dropped)) == [LogLine.deferredGaveUp, .showGoToEnd])
        #expect(harness.state.fallback == .none)
        #expect(harness.state.owner == .idle)
        #expect(harness.state.currentRecovery == nil)
        #expect(!harness.isLive(follow2))
        #expect(harness.userIsScrolledAway)
        #expect(harness.goToEndShown == 1)
        #expect(harness.rePins == 0)
        #expect(harness.scrolls == 1)
        #expect(harness.send(.followFinished(follow2, .dropped)).isEmpty)
        #expect(harness.goToEndShown == 1)
    }

    /// Migrated from `deferredGiveUpShowsGoToEndWhenTheFollowIsDropped`
    /// (the executed half): a follow that executed clears the transfer and
    /// re-arms the recovery instead of showing Go to End — automatic (no
    /// landing) or forced, whatever its landing. Without a transfer, a
    /// dropped automatic follow's drain is the raw edge replay.
    @Test func aTransferredGiveUpIsClearedByAnyExecutedDrainWhichReArmsTheRecovery() {
        var automatic = transferredGiveUp(forced: false)
        automatic.distanceToBottom = 30
        #expect(automatic.execute())
        #expect(automatic.send(.followDue(follow2, execute: true)) == [.scrollToEnd])
        #expect(automatic.send(.followFinished(follow2, .executed(nil))) == [
            .replayLiveEdge(.live), .startRecoveryTask(recovery3)
        ])
        #expect(automatic.state.fallback == .none)
        #expect(automatic.state.owner == .idle)
        #expect(automatic.state.armedRecovery == .polling(recovery3))
        #expect(automatic.isLive(recovery3))
        #expect(automatic.goToEndShown == 0)
        #expect(!automatic.userIsScrolledAway)

        for landing in [ConversationTranscriptScrollPolicy.FollowLandingTerminal.landed, .giveUp, .yieldToUser] {
            var forced = transferredGiveUp(forced: true)
            #expect(forced.execute())
            #expect(forced.send(.followDue(follow2, execute: true)) == [.scrollToEnd])
            #expect(forced.send(.followFinished(follow2, .executed(landing))) == [.startRecoveryTask(recovery3)])
            #expect(forced.state.fallback == .none)
            #expect(forced.state.armedRecovery == .polling(recovery3))
            #expect(forced.goToEndShown == 0)
            #expect(!forced.userIsScrolledAway)
        }

        var plain = makeHarness()
        #expect(plain.send(.followRequested(forced: false)) == [.startFollowTask(follow1, forced: false)])
        plain.distanceToBottom = 120
        #expect(!plain.execute())
        #expect(plain.send(.followDue(follow1, execute: false)).isEmpty)
        #expect(plain.send(.followFinished(follow1, .dropped)) == [.replayLiveEdge(.live)])
        #expect(plain.state.fallback == .none)
        #expect(plain.goToEndShown == 0)
        #expect(!plain.userIsScrolledAway)
        #expect(plain.rePins == 1)
    }

    /// Scenario 3 (7e0ecbc): the transferred give-up does not depend on the
    /// follow executing. A forced follow yielding to the finger and an
    /// automatic one a gesture cancels each show Go to End once; the
    /// cancelled task's own terminal is stale.
    @Test func aTransferredGiveUpIsDischargedOnceByYieldOrCancel() {
        var yielded = transferredGiveUp(forced: true)
        yielded.isInteracting = true
        #expect(!yielded.execute())
        #expect(yielded.send(.followDue(follow2, execute: false)) == [LogLine.forcedYielded, .replayLiveEdge(.sampled(isInteracting: true))])
        #expect(!yielded.userIsScrolledAway)
        #expect(yielded.send(.followFinished(follow2, .yielded)) == [LogLine.deferredGaveUp, .showGoToEnd])
        #expect(yielded.state.fallback == .none)
        #expect(yielded.state.owner == .idle)
        #expect(yielded.userIsScrolledAway)
        #expect(yielded.goToEndShown == 1)
        #expect(yielded.send(.followFinished(follow2, .yielded)).isEmpty)
        #expect(yielded.goToEndShown == 1)

        var cancelled = transferredGiveUp(forced: false)
        #expect(cancelled.gestureBegins(distanceToBottom: 200) == [
            .cancelFollowTask(follow2), LogLine.deferredGaveUp, .showGoToEnd
        ])
        #expect(cancelled.state.fallback == .none)
        #expect(cancelled.state.owner == .idle)
        #expect(!cancelled.isLive(follow2))
        #expect(cancelled.goToEndShown == 1)
        #expect(cancelled.send(.followFinished(follow2, .cancelled)).isEmpty)
        #expect(cancelled.goToEndShown == 1)
        #expect(cancelled.scrolls == 0)
    }

    /// Scenario 3, continued: a follow a newer request replaces hands the
    /// transfer to the replacing token — today's
    /// `scrollDebounceTask?.cancel()` in `scrollToBottom` resolves no
    /// deferral, so it survives to the replacing follow's drain, which
    /// re-arms the recovery if it executed and shows Go to End if it did
    /// not. The replaced task's own terminal is stale.
    @Test func aTransferredGiveUpIsHandedToAReplacingFollowAndDischargedByItsDrain() {
        var replaced = transferredGiveUp(forced: false)
        #expect(replaced.send(.explicitClaim).isEmpty)
        #expect(replaced.send(.followRequested(forced: true)) == [
            .cancelFollowTask(follow2), .startFollowTask(follow3, forced: true)
        ])
        #expect(replaced.state.fallback == .transferred(follow: follow3))
        #expect(!replaced.isLive(follow2))
        #expect(replaced.isLive(follow3))
        #expect(replaced.send(.followFinished(follow2, .replaced)).isEmpty)
        #expect(replaced.state.fallback == .transferred(follow: follow3))
        #expect(replaced.goToEndShown == 0)
        var replacementYielded = replaced
        #expect(replaced.execute())
        #expect(replaced.send(.followDue(follow3, execute: true)) == [.scrollToEnd])
        #expect(replaced.send(.followFinished(follow3, .executed(.landed))) == [.startRecoveryTask(recovery4)])
        #expect(replaced.state.fallback == .none)
        #expect(replaced.state.armedRecovery == .polling(recovery4))
        #expect(replaced.goToEndShown == 0)
        #expect(!replaced.userIsScrolledAway)
        replacementYielded.isInteracting = true
        #expect(!replacementYielded.execute())
        #expect(replacementYielded.send(.followDue(follow3, execute: false)) == [
            LogLine.forcedYielded, .replayLiveEdge(.sampled(isInteracting: true))
        ])
        #expect(replacementYielded.send(.followFinished(follow3, .yielded)) == [LogLine.deferredGaveUp, .showGoToEnd])
        #expect(replacementYielded.state.fallback == .none)
        #expect(replacementYielded.state.currentRecovery == nil)
        #expect(replacementYielded.goToEndShown == 1)
    }

    /// The transfer over an end row that realized before the follow drained
    /// clears silently: the dropped follow's replayed edge re-pins the
    /// viewport to the realized row by the growth path.
    @Test func aTransferOverAnEndRowThatRealizedMeanwhileClearsSilently() {
        var harness = transferredGiveUp(forced: false)
        #expect(harness.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        harness.distanceToBottom = 120
        #expect(!harness.execute())
        #expect(harness.send(.followDue(follow2, execute: false)).isEmpty)
        #expect(harness.send(.followFinished(follow2, .dropped)) == [.replayLiveEdge(.live)])
        #expect(harness.state.fallback == .none)
        #expect(harness.goToEndShown == 0)
        #expect(!harness.userIsScrolledAway)
        #expect(harness.rePins == 1)
    }

    /// Scenario 4 (b0c0941; migrated from
    /// `followDrainingOverAnUnrealizedEndRowArmsTheRecovery`): Go to End
    /// over a blank with nothing armed. The tap's forced follow executes and
    /// drains with the end row still unrealized, so the recovery is
    /// re-armed from the level — whatever the landing reported — and judges
    /// the blank from geometry; a follow that yielded landed nowhere and
    /// arms nothing; a realized end row needs nothing either way.
    @Test func aForcedFollowDrainingOverAnAlreadyUnrealizedEndRowReArmsTheRecovery() {
        var harness = makeHarness(realized: false, scrolledAway: true)
        #expect(harness.tapGoToEnd() == [.startFollowTask(follow1, forced: true)])
        #expect(!harness.userIsScrolledAway)
        #expect(harness.state.currentRecovery == nil)
        var yielded = harness
        #expect(harness.execute())
        #expect(harness.send(.followDue(follow1, execute: true)) == [.scrollToEnd])
        var gaveUp = harness
        var realizedFirst = harness
        #expect(harness.send(.followFinished(follow1, .executed(.landed))) == [.startRecoveryTask(recovery2)])
        #expect(harness.state.owner == .idle)
        #expect(harness.state.armedRecovery == .polling(recovery2))
        #expect(harness.isLive(recovery2))
        #expect(harness.poll(blank) == .continue(.recover(pageOffsetY: 1600)))
        #expect(harness.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(harness.poll(blank) == .finish(.notNeeded))

        #expect(gaveUp.send(.followFinished(follow1, .executed(.giveUp))) == [.startRecoveryTask(recovery2)])
        #expect(gaveUp.state.armedRecovery == .polling(recovery2))

        #expect(realizedFirst.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(realizedFirst.send(.followFinished(follow1, .executed(.landed))).isEmpty)
        #expect(realizedFirst.state.currentRecovery == nil)

        yielded.isInteracting = true
        #expect(!yielded.execute())
        #expect(yielded.send(.followDue(follow1, execute: false)) == [LogLine.forcedYielded, .replayLiveEdge(.sampled(isInteracting: true))])
        #expect(yielded.send(.followFinished(follow1, .yielded)).isEmpty)
        #expect(yielded.state.owner == .idle)
        #expect(yielded.state.currentRecovery == nil)
        #expect(yielded.scrolls == 0)

        var yieldedRealized = makeHarness(realized: true, scrolledAway: true)
        #expect(yieldedRealized.tapGoToEnd() == [.startFollowTask(follow1, forced: true)])
        yieldedRealized.isInteracting = true
        #expect(!yieldedRealized.execute())
        #expect(yieldedRealized.send(.followDue(follow1, execute: false)) == [
            LogLine.forcedYielded, .replayLiveEdge(.sampled(isInteracting: true))
        ])
        #expect(yieldedRealized.send(.followFinished(follow1, .yielded)).isEmpty)
        #expect(yieldedRealized.state.currentRecovery == nil)
    }

    /// Scenario 4, continued: an automatic follow (the user's message) that
    /// executed re-arms the recovery the same way; one that was dropped
    /// landed nowhere and arms nothing; a realized end row needs nothing.
    @Test func anAutomaticFollowDrainingOverAnAlreadyUnrealizedEndRowReArmsTheRecovery() {
        var automatic = makeHarness(realized: false)
        #expect(automatic.send(.followRequested(forced: false)) == [.startFollowTask(follow1, forced: false)])
        var dropped = automatic
        automatic.distanceToBottom = 30
        var realizedAutomatic = automatic
        #expect(automatic.execute())
        #expect(automatic.send(.followDue(follow1, execute: true)) == [.scrollToEnd])
        #expect(automatic.send(.followFinished(follow1, .executed(nil))) == [
            .replayLiveEdge(.live), .startRecoveryTask(recovery2)
        ])
        #expect(automatic.state.armedRecovery == .polling(recovery2))
        #expect(automatic.isLive(recovery2))
        #expect(automatic.poll(blank) == .continue(.recover(pageOffsetY: 1600)))

        #expect(realizedAutomatic.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(realizedAutomatic.send(.followDue(follow1, execute: true)) == [.scrollToEnd])
        #expect(realizedAutomatic.send(.followFinished(follow1, .executed(nil))) == [.replayLiveEdge(.live)])
        #expect(realizedAutomatic.state.currentRecovery == nil)

        dropped.distanceToBottom = 120
        #expect(!dropped.execute())
        #expect(dropped.send(.followDue(follow1, execute: false)).isEmpty)
        #expect(dropped.send(.followFinished(follow1, .dropped)) == [.replayLiveEdge(.live)])
        #expect(dropped.state.currentRecovery == nil)
        #expect(dropped.goToEndShown == 0)
    }
}
