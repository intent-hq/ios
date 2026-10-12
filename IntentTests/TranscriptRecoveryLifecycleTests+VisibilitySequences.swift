import Foundation
@testable import Intent
import Testing

/// A new visible visit receives fresh tokens while preserving bounded
/// recovery and the user's ability to take over the viewport.
extension TranscriptRecoveryLifecycleTests {
    @Test(arguments: [false, true])
    func cancelledVisitCallbacksCannotAffectTheNextVisitsOwners(forced: Bool) {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.send(.followRequested(forced: forced)) == [.startFollowTask(follow2, forced: forced)])
        #expect(harness.send(.viewDisappeared) == [.cancelFollowTask(follow2), .cancelRecoveryTask(recovery1)])
        let lateEvents = lateLifecycleEvents(follow: follow2, recovery: recovery1)
        expectIgnored(lateEvents, by: &harness)
        expectIgnored([
            .followRequested(forced: false), .followRequested(forced: true), .explicitClaim, .followCancelledByGesture
        ], by: &harness)
        #expect(harness.liveFollows.isEmpty)
        #expect(harness.liveRecoveries.isEmpty)
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.send(.viewAppeared) == [.startRecoveryTask(recovery3)])
        expectIgnored(lateEvents, by: &harness)
        #expect(harness.liveRecoveries == [recovery3])
        #expect(harness.send(.recoveryStep(recovery3, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        expectIgnored(lateEvents, by: &harness)
        let newFollow = FollowToken(id: 4)
        #expect(harness.send(.followRequested(forced: forced)) == [.startFollowTask(newFollow, forced: forced)])
        #expect(harness.state.armedRecovery == .demoted(recovery3))
        expectIgnored(lateEvents, by: &harness)
        #expect(harness.liveFollows == [newFollow])
        #expect(harness.liveRecoveries == [recovery3])
        #expect(harness.send(.followDue(newFollow, execute: true)) == [.scrollToEnd])
        let drainEffects: [Effect] = forced ? [] : [.replayLiveEdge(.live)]
        #expect(harness.send(.followFinished(newFollow, .executed(.landed))) == drainEffects)
        #expect(harness.state.owner == .recovery(recovery3))
        #expect(harness.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(harness.send(.recoveryFinished(recovery3, .notNeeded, corrections: 1)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 1), .replayLiveEdge(.live)
        ])
        #expect(harness.state == State(visibility: .visible, isEndRealized: true, nextTokenId: 5))
        #expect(harness.liveFollows.isEmpty)
        #expect(harness.liveRecoveries.isEmpty)
        #expect(harness.pageUps == [1600])
        #expect(harness.scrolls == 1)
        #expect(harness.outcomes == [.recordRecoveryOutcome(.notNeeded, corrections: 1)])
        #expect(harness.goToEndShown == 0)
    }

    @Test func reappearedRecoveryKeepsItsBudgetThroughDuplicateAppearanceAndFollowHandoff() {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.send(.viewDisappeared) == [.cancelRecoveryTask(recovery1)])
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.send(.viewAppeared) == [.startRecoveryTask(recovery2)])
        #expect(harness.poll(blank) == .continue(.recover(pageOffsetY: 1600)))
        #expect(harness.send(.recoveryStep(recovery2, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        #expect(harness.send(.viewAppeared).isEmpty)
        #expect(harness.send(.followRequested(forced: false)) == [.startFollowTask(follow3, forced: false)])
        #expect(harness.state.armedRecovery == .demoted(recovery2))
        #expect(harness.send(.viewAppeared).isEmpty)
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.send(.followFinished(follow3, .dropped)) == [.replayLiveEdge(.live)])
        #expect(harness.state.owner == .recovery(recovery2))
        #expect(harness.send(.recoveryPagedUp(recovery2, mayFollowBack: true)) == [.scrollToEnd])
        #expect(harness.poll(blank, correctionsLeft: 1, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 0)))
        #expect(harness.send(.recoveryStep(recovery2, .recover(pageOffsetY: 0))) == [LogLine.pageUp, .pageUp(offsetY: 0)])
        #expect(harness.send(.recoveryPagedUp(recovery2, mayFollowBack: true)) == [.scrollToEnd])
        #expect(harness.poll(blank, correctionsLeft: 0, correctionsSpent: 2) == .finish(.giveUp))
        #expect(harness.poll(blank, correctionsSpent: 2, timedOut: true) == .finish(.giveUp))
        #expect(harness.send(.recoveryFinished(recovery2, .giveUp, corrections: 2)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 2), LogLine.gaveUp, .showGoToEnd
        ])
        #expect(harness.send(.viewAppeared).isEmpty)
        #expect(harness.state == State(visibility: .visible, nextTokenId: 4))
        #expect(harness.episodes == 2)
        #expect(harness.liveRecoveries.isEmpty)
        #expect(harness.liveFollows.isEmpty)
        #expect(harness.pageUps == [1600, 0])
        #expect(harness.scrolls == 2)
        #expect(harness.goToEndShown == 1)
        #expect(harness.userIsScrolledAway)
        #expect(harness.rePins == 0)
        #expect(harness.summaries == ["endRecovery=gaveUp corrections=2 episodes=2 endRealized=false"])
    }

    @Test(arguments: [false, true])
    func aGestureAfterReappearanceCancelsTheFollowAndDemotedRecovery(forced: Bool) {
        var harness = makeHarness()
        #expect(harness.send(.viewDisappeared).isEmpty)
        #expect(harness.send(.viewAppeared) == [.startRecoveryTask(recovery1)])
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        #expect(harness.send(.followRequested(forced: forced)) == [.startFollowTask(follow2, forced: forced)])
        #expect(nonLog(harness.gestureBegins(distanceToBottom: 700)) == [.cancelFollowTask(follow2), .cancelRecoveryTask(recovery1)])
        #expect(harness.state == State(visibility: .visible, nextTokenId: 3))
        #expect(harness.userIsScrolledAway)
        #expect(!harness.mayFollowBack())
        #expect(harness.liveFollows.isEmpty)
        #expect(harness.liveRecoveries.isEmpty)
        expectIgnored(lateLifecycleEvents(follow: follow2, recovery: recovery1), by: &harness)
        #expect(harness.send(.viewAppeared).isEmpty)
        #expect(harness.episodes == 1)
        #expect(harness.pageUps == [1600])
        #expect(harness.scrolls == 0)
        #expect(harness.rePins == 0)
        #expect(harness.goToEndShown == 0)
        #expect(harness.outcomes.isEmpty)
    }

    @Test func aGestureAfterReappearanceTakesOverAnOwningRecovery() {
        var harness = makeHarness()
        #expect(harness.send(.viewDisappeared).isEmpty)
        #expect(harness.send(.viewAppeared) == [.startRecoveryTask(recovery1)])
        #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
        #expect(harness.gestureBegins(distanceToBottom: 700) == [.cancelRecoveryTask(recovery1)])
        #expect(harness.state == State(visibility: .visible, nextTokenId: 2))
        expectIgnored(lateLifecycleEvents(follow: staleFollow, recovery: recovery1), by: &harness)
        #expect(harness.userIsScrolledAway)
        #expect(harness.liveRecoveries.isEmpty)
        #expect(harness.pageUps == [1600])
        #expect(harness.scrolls == 0)
        #expect(harness.rePins == 0)
        #expect(harness.outcomes.isEmpty)
    }
}
