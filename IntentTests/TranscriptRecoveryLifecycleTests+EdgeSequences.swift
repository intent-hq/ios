import CoreGraphics
@testable import Intent
import Testing

/// The #350 handoff defects (scenarios 5, 6) and the migrated
/// correction / give-up sequences replayed through `LifecycleHarness`.
extension TranscriptRecoveryLifecycleTests {
    /// Scenario 5 (7e0ecbc, e3cd988): the recovery spends its budget over
    /// the blank and shows Go to End. A viewport over an unrealized end row
    /// reads "at bottom" while showing nothing (#338), so the blank's
    /// at-bottom edges — a layout settle, a gesture ending there, a bounce
    /// — clear nothing and re-pin nothing over the button, and its away
    /// edges are as before. The row realizing replays the live edge, and
    /// only then does the ordinary rule apply: cleared at the bottom, growth
    /// re-pinned, a drag away scrolled away.
    @Test func anAtBottomEdgeOverTheBlankKeepsGoToEndUntilTheMarkerRealizes() {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.poll(blank) == .continue(.recover(pageOffsetY: 1600)))
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        harness.distanceToBottom = 700
        #expect(harness.mayFollowBack())
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: true)) == [.scrollToEnd])
        harness.distanceToBottom = 0
        #expect(harness.poll(blank, correctionsLeft: 1, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 0)))
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 0))) == [LogLine.pageUp, .pageUp(offsetY: 0)])
        let secondFollowBack = harness.mayFollowBack()
        #expect(secondFollowBack)
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: secondFollowBack)) == [.scrollToEnd])
        #expect(harness.poll(blank, correctionsLeft: 0, correctionsSpent: 2) == .finish(.giveUp))
        #expect(harness.send(.recoveryFinished(recovery1, .giveUp, corrections: 2)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 2), LogLine.gaveUp, .showGoToEnd
        ])
        #expect(harness.state.owner == .idle)
        #expect(harness.state.currentRecovery == nil)
        #expect(harness.userIsScrolledAway)
        #expect(harness.scrolls == 2)
        #expect(harness.pageUps == [1600, 0])

        harness.geometryEdge(distanceToBottom: 0)
        #expect(harness.userIsScrolledAway)
        harness.geometryEdge(distanceToBottom: 40, isInteracting: true)
        #expect(harness.userIsScrolledAway)
        harness.geometryEdge(distanceToBottom: -30)
        #expect(harness.userIsScrolledAway)
        harness.geometryEdge(distanceToBottom: 120)
        #expect(harness.userIsScrolledAway)
        #expect(harness.rePins == 0)
        #expect(harness.scrolls == 2)

        harness.distanceToBottom = 0
        #expect(harness.send(.endRealized(userIsScrolledAway: true)) == [.replayLiveEdge(.live)])
        #expect(harness.state.isEndRealized)
        #expect(!harness.userIsScrolledAway)
        #expect(harness.rePins == 0)
        #expect(harness.goToEndShown == 1)
        harness.geometryEdge(distanceToBottom: 120)
        #expect(!harness.userIsScrolledAway)
        #expect(harness.rePins == 1)
        harness.geometryEdge(distanceToBottom: 120, isInteracting: true)
        #expect(harness.userIsScrolledAway)
        harness.geometryEdge(distanceToBottom: 40, isInteracting: true)
        #expect(!harness.userIsScrolledAway)
    }

    /// Scenario 5, continued: a pinned viewport over the blank is kept
    /// pinned the same way — its at-bottom and away edges clear nothing
    /// until a gesture's own away edge does.
    @Test func aPinnedViewportOverTheBlankStaysPinnedUntilAGestureScrollsAway() {
        var pinned = makeHarness()
        #expect(pinned.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        pinned.geometryEdge(distanceToBottom: 0)
        #expect(!pinned.userIsScrolledAway)
        pinned.geometryEdge(distanceToBottom: 120)
        #expect(!pinned.userIsScrolledAway)
        pinned.geometryEdge(distanceToBottom: 120, isInteracting: true)
        #expect(pinned.userIsScrolledAway)
    }

    /// Scenario 6: a completed follow's terminal replayed after a new
    /// follow was requested, and a cancelled recovery's continuations, are
    /// stale — no state change, no effect, no outcome — while the current
    /// tokens keep going.
    @Test func staleContinuationsAfterAReplacementAndAClaimChangeNothing() {
        var harness = makeHarness()
        #expect(harness.send(.followRequested(forced: false)) == [.startFollowTask(follow1, forced: false)])
        #expect(harness.send(.followDue(follow1, execute: true)) == [.scrollToEnd])
        #expect(harness.send(.followFinished(follow1, .executed(nil))) == [.replayLiveEdge(.live)])
        #expect(harness.state.owner == .idle)
        #expect(!harness.isLive(follow1))
        #expect(harness.send(.followRequested(forced: true)) == [.startFollowTask(follow2, forced: true)])
        let afterRequest = harness.state
        #expect(harness.send(.followFinished(follow1, .executed(nil))).isEmpty)
        #expect(harness.send(.followDue(follow1, execute: true)).isEmpty)
        #expect(harness.send(.followFinished(follow1, .dropped)).isEmpty)
        #expect(harness.state == afterRequest)
        #expect(harness.scrolls == 1)

        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery3)])
        #expect(harness.send(.explicitClaim) == [.cancelRecoveryTask(recovery3)])
        #expect(!harness.isLive(recovery3))
        let afterClaim = harness.state
        #expect(harness.send(.recoveryStep(recovery3, .followToEnd)).isEmpty)
        #expect(harness.send(.recoveryStep(recovery3, .recover(pageOffsetY: 0))).isEmpty)
        #expect(harness.send(.recoveryPagedUp(recovery3, mayFollowBack: true)).isEmpty)
        #expect(harness.send(.recoveryFinished(recovery3, .giveUp, corrections: 1)).isEmpty)
        #expect(harness.state == afterClaim)
        #expect(harness.outcomes.isEmpty)
        #expect(harness.goToEndShown == 0)
        #expect(harness.scrolls == 1)

        #expect(harness.send(.followDue(follow2, execute: true)) == [.scrollToEnd])
        #expect(harness.send(.followFinished(follow2, .executed(.landed))) == [.startRecoveryTask(recovery4)])
        #expect(harness.state.armedRecovery == .polling(recovery4))
        #expect(harness.liveRecoveries == [recovery4])
        #expect(harness.liveFollows.isEmpty)
    }

    /// Migrated from `recoveryDrainReplaysTheEdgeTheCorrectionSuppressed`: a
    /// correction in flight counts as a follow, so an away edge under it
    /// neither scrolls away nor re-pins; the drain replays that edge with
    /// the flag released. Recovered (the end row realized) short of the
    /// end, the viewport is re-pinned by the growth path; yielded to a
    /// follow that claimed the viewport, the landing is the follow's and the
    /// replay re-pins nothing over it; recovered at the bottom, the edge
    /// does nothing.
    @Test func aCorrectionSuppressesTheGrowthRePinUntilItsDrainReplaysTheEdge() {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.poll(geometry(offsetY: 260)) == .continue(.followToEnd))
        #expect(harness.send(.recoveryStep(recovery1, .followToEnd)) == [LogLine.followToEnd, .scrollToEnd])
        #expect(harness.state.isFollowing)
        harness.geometryEdge(distanceToBottom: 120)
        #expect(!harness.userIsScrolledAway)
        #expect(harness.rePins == 0)
        #expect(harness.poll(geometry(offsetY: 260), correctionsLeft: 1, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 0)))
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 0))) == [LogLine.pageUp, .pageUp(offsetY: 0)])
        harness.distanceToBottom = 300
        var toFollow = harness

        #expect(harness.mayFollowBack())
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: true)) == [.scrollToEnd])
        #expect(harness.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        var atBottom = harness
        harness.distanceToBottom = 120
        #expect(harness.poll(geometry(offsetY: 180), correctionsSpent: 2) == .finish(.notNeeded))
        #expect(harness.send(.recoveryFinished(recovery1, .notNeeded, corrections: 2)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 2), .replayLiveEdge(.live)
        ])
        #expect(harness.state.owner == .idle)
        #expect(!harness.state.isFollowing)
        #expect(!harness.userIsScrolledAway)
        #expect(harness.rePins == 1)
        #expect(harness.goToEndShown == 0)

        atBottom.distanceToBottom = 10
        #expect(atBottom.send(.recoveryFinished(recovery1, .notNeeded, corrections: 2)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 2), .replayLiveEdge(.live)
        ])
        #expect(!atBottom.userIsScrolledAway)
        #expect(atBottom.rePins == 0)

        #expect(toFollow.send(.followRequested(forced: false)) == [.startFollowTask(follow2, forced: false)])
        #expect(toFollow.state.armedRecovery == .demoted(recovery1))
        #expect(!toFollow.mayFollowBack())
        #expect(toFollow.send(.recoveryPagedUp(recovery1, mayFollowBack: false)) == [LogLine.recoveryYielded])
        toFollow.distanceToBottom = 120
        #expect(toFollow.send(.recoveryFinished(recovery1, .yieldToUser, corrections: 2)) == [
            .recordRecoveryOutcome(.yieldToUser, corrections: 2), .replayLiveEdge(.live)
        ])
        #expect(toFollow.state.owner == .follow(follow2, forced: false))
        #expect(toFollow.state.armedRecovery == nil)
        #expect(!toFollow.userIsScrolledAway)
        #expect(toFollow.rePins == 0)
        #expect(toFollow.scrolls == 1)
    }

    /// Migrated from `recoveryDrainReplaysTheEdgeTheCorrectionSuppressed`
    /// (the yielded half): a correction yielded under the finger drains with
    /// the edge as the gesture it is — scrolled away, nothing scrolls the
    /// user back, and the outcome reports as `endRecovery=yieldedToUser`.
    @Test func aCorrectionYieldedUnderTheFingerDrainsAsTheGestureEdge() {
        var yielded = makeHarness()
        #expect(yielded.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(yielded.poll(blank) == .continue(.recover(pageOffsetY: 1600)))
        #expect(yielded.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        yielded.isInteracting = true
        yielded.distanceToBottom = 120
        #expect(!yielded.mayFollowBack())
        #expect(yielded.send(.recoveryPagedUp(recovery1, mayFollowBack: false)) == [LogLine.recoveryYielded])
        #expect(yielded.send(.recoveryFinished(recovery1, .yieldToUser, corrections: 1)) == [
            .recordRecoveryOutcome(.yieldToUser, corrections: 1), .replayLiveEdge(.live)
        ])
        #expect(yielded.summaries == ["endRecovery=yieldedToUser corrections=1 episodes=1 endRealized=false"])
        #expect(yielded.userIsScrolledAway)
        #expect(yielded.rePins == 0)
        #expect(yielded.goToEndShown == 0)
        #expect(yielded.scrolls == 0)
    }

    /// A correction pages up and an automatic follow is requested during
    /// the settle: the follow owns and the recovery is demoted, so the
    /// page-up check reads a follow pending and the recovery yields. The
    /// yield is still logged once — the follow, not the user, has the
    /// paged-up viewport, so nothing scrolls over it — and the recovery
    /// finishes with its outcome and the replayed edge, leaving the follow
    /// the owner and its task live.
    @Test func aPageUpDemotedByAnAutomaticFollowDuringTheSettleLogsItsYieldWithoutScrolling() {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.poll(blank) == .continue(.recover(pageOffsetY: 1600)))
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        #expect(harness.state.owner == .recovery(recovery1))
        #expect(harness.pageUps == [1600])
        #expect(harness.send(.followRequested(forced: false)) == [.startFollowTask(follow2, forced: false)])
        #expect(harness.state.owner == .follow(follow2, forced: false))
        #expect(harness.state.armedRecovery == .demoted(recovery1))
        #expect(harness.isLive(recovery1))
        #expect(harness.isLive(follow2))
        harness.distanceToBottom = 1600
        #expect(!harness.mayFollowBack())
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: false)) == [LogLine.recoveryYielded])
        #expect(harness.state.owner == .follow(follow2, forced: false))
        #expect(harness.state.armedRecovery == .demoted(recovery1))
        #expect(harness.scrolls == 0)
        #expect(harness.send(.recoveryFinished(recovery1, .yieldToUser, corrections: 1)) == [
            .recordRecoveryOutcome(.yieldToUser, corrections: 1), .replayLiveEdge(.live)
        ])
        #expect(harness.summaries == ["endRecovery=yieldedToUser corrections=1 episodes=1 endRealized=false"])
        #expect(harness.state.owner == .follow(follow2, forced: false))
        #expect(harness.state.armedRecovery == nil)
        #expect(harness.state.currentRecovery == nil)
        #expect(!harness.isLive(recovery1))
        #expect(harness.isLive(follow2))
        #expect(!harness.userIsScrolledAway)
        #expect(harness.rePins == 0)
        #expect(harness.goToEndShown == 0)
        #expect(harness.scrolls == 0)
        // The finished token's page-up is stale either way.
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: false)).isEmpty)
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: true)).isEmpty)
        #expect(harness.scrolls == 0)
    }

    /// Migrated from `recoveryGiveUpShowsGoToEndInsteadOfRePinningBlind`:
    /// the budget spent short of the end inside the band (or the deadline
    /// passed at the bottom over the blank) gives up, and the give-up shows
    /// Go to End where the edge alone would have re-pinned blind to a row
    /// that is not there. Scrolled away, growth re-pins nothing over the
    /// button; the tap follows through the verified path and its executed
    /// drain re-arms the recovery from the level. The outcome reports as
    /// `endRecovery=gaveUp` with the corrections spent.
    @Test func aGiveUpShowsGoToEndInsteadOfRePinningBlind() {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.poll(geometry(offsetY: 260)) == .continue(.followToEnd))
        #expect(harness.send(.recoveryStep(recovery1, .followToEnd)) == [LogLine.followToEnd, .scrollToEnd])
        #expect(harness.poll(geometry(offsetY: 260), correctionsLeft: 1, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 0)))
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 0))) == [LogLine.pageUp, .pageUp(offsetY: 0)])
        harness.distanceToBottom = 300
        let followBack = harness.mayFollowBack()
        #expect(followBack)
        #expect(harness.send(.recoveryPagedUp(recovery1, mayFollowBack: followBack)) == [.scrollToEnd])
        harness.distanceToBottom = 40
        #expect(harness.poll(geometry(offsetY: 260), correctionsLeft: 0, correctionsSpent: 2) == .finish(.giveUp))
        #expect(harness.poll(geometry(offsetY: 300), correctionsSpent: 2, timedOut: true) == .finish(.giveUp))
        harness.isInteracting = true
        #expect(harness.poll(geometry(offsetY: 300), timedOut: true) == .finish(.giveUp))
        harness.isInteracting = false
        #expect(harness.send(.recoveryFinished(recovery1, .giveUp, corrections: 2)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 2), LogLine.gaveUp, .showGoToEnd
        ])
        #expect(harness.summaries == ["endRecovery=gaveUp corrections=2 episodes=1 endRealized=false"])
        #expect(harness.userIsScrolledAway)
        #expect(harness.goToEndShown == 1)
        #expect(harness.rePins == 0)
        #expect(harness.scrolls == 2)
        #expect(harness.state.owner == .idle)
        #expect(harness.state.currentRecovery == nil)
        harness.geometryEdge(distanceToBottom: 120)
        #expect(harness.userIsScrolledAway)
        #expect(harness.rePins == 0)
        #expect(harness.tapGoToEnd() == [.startFollowTask(follow2, forced: true)])
        #expect(!harness.userIsScrolledAway)
        harness.distanceToBottom = 40
        #expect(harness.execute())
        #expect(harness.send(.followDue(follow2, execute: true)) == [.scrollToEnd])
        #expect(harness.send(.followFinished(follow2, .executed(.landed))) == [.startRecoveryTask(recovery3)])
        #expect(harness.state.armedRecovery == .polling(recovery3))
        #expect(harness.isLive(recovery3))
        #expect(harness.goToEndShown == 1)
        #expect(harness.scrolls == 3)
    }
}
