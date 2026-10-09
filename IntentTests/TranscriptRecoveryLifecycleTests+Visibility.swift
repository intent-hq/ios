import Foundation
@testable import Intent
import Testing

/// Parent and end-marker callback ordering, including callbacks that arrive
/// after teardown while the transcript remains mounted but inactive.
extension TranscriptRecoveryLifecycleTests {
    @Test(arguments: [false, true])
    func inactiveMarkerCallbacksOnlyUpdateRealization(scrolledAway: Bool) {
        var state = State(nextTokenId: 7)
        #expect(step(&state, .endRealized(userIsScrolledAway: scrolledAway)).isEmpty)
        #expect(state == State(isEndRealized: true, nextTokenId: 7))
        #expect(step(&state, .endRealized(userIsScrolledAway: scrolledAway)).isEmpty)
        #expect(step(&state, .endDerealized).isEmpty)
        #expect(step(&state, .endDerealized).isEmpty)
        #expect(state == State(nextTokenId: 7))
    }

    @Test(arguments: [false, true])
    func inactiveRequestsAndTaskCallbacksHaveNoEffects(realized: Bool) {
        let original = State(isEndRealized: realized, nextTokenId: 7)
        var state = original
        let requests: [Event] = [
            .followRequested(forced: false), .followRequested(forced: true), .explicitClaim, .followCancelledByGesture
        ]
        for event in requests + lateLifecycleEvents(follow: follow1, recovery: recovery2) {
            #expect(step(&state, event).isEmpty, "\(event)")
            #expect(state == original, "\(event)")
        }
    }

    @Test(arguments: [false, true])
    func parentFirstAppearanceStartsOneRecoveryOnEachVisit(scrolledAway: Bool) {
        var harness = makeInactiveHarness()
        for visit in 1...2 {
            let recovery = RecoveryToken(id: visit)
            harness.userIsScrolledAway = scrolledAway
            #expect(harness.send(.viewAppeared) == [.startRecoveryTask(recovery)])
            #expect(harness.state.isVisible)
            #expect(harness.state.armedRecovery == .polling(recovery))
            #expect(harness.send(.viewAppeared).isEmpty)
            #expect(harness.episodes == visit)
            let realizedEffects: [Effect] = scrolledAway ? [.replayLiveEdge(.live)] : []
            #expect(harness.send(.endRealized(userIsScrolledAway: scrolledAway)) == realizedEffects)
            #expect(harness.state.isEndRealized)
            #expect(harness.state.currentRecovery == recovery)
            #expect(harness.send(.recoveryFinished(recovery, .notNeeded, corrections: 0)) == [
                .recordRecoveryOutcome(.notNeeded, corrections: 0), .replayLiveEdge(.live)
            ])
            #expect(harness.send(.viewAppeared).isEmpty)
            #expect(harness.liveRecoveries.isEmpty)
            #expect(harness.send(.viewDisappeared).isEmpty)
            #expect(harness.state == State(nextTokenId: visit + 1))
        }
        #expect(harness.scrolls == 0)
        #expect(harness.rePins == 0)
    }

    @Test(arguments: [false, true])
    func childFirstAppearancePreservesRealizationWithoutStartingRecovery(scrolledAway: Bool) {
        var harness = makeInactiveHarness()
        for _ in 0..<2 {
            harness.userIsScrolledAway = scrolledAway
            #expect(harness.send(.endRealized(userIsScrolledAway: scrolledAway)).isEmpty)
            #expect(harness.userIsScrolledAway == scrolledAway)
            #expect(harness.send(.viewAppeared).isEmpty)
            #expect(harness.state == State(visibility: .visible, isEndRealized: true))
            #expect(harness.send(.viewAppeared).isEmpty)
            #expect(harness.episodes == 0)
            #expect(harness.liveRecoveries.isEmpty)
            #expect(harness.send(.viewDisappeared).isEmpty)
            #expect(harness.state == State())
        }
        #expect(harness.send(.viewAppeared) == [.startRecoveryTask(recovery1)])
        #expect(harness.state.armedRecovery == .polling(recovery1))
        #expect(harness.scrolls == 0)
        #expect(harness.rePins == 0)
    }

    @Test func aChildThatDerealizesBeforeAppearanceDefersRecoveryUntilTheParentAppears() {
        var harness = makeInactiveHarness()
        #expect(harness.send(.endRealized(userIsScrolledAway: true)).isEmpty)
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.state == State())
        #expect(harness.episodes == 0)
        #expect(harness.send(.viewAppeared) == [.startRecoveryTask(recovery1)])
        #expect(harness.send(.viewAppeared).isEmpty)
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.liveRecoveries == [recovery1])
        #expect(harness.episodes == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func disappearanceCancelsAnActiveFollowInEitherOrder(forced: Bool, parentFirst: Bool) {
        var harness = makeHarness()
        #expect(harness.send(.followRequested(forced: forced)) == [.startFollowTask(follow1, forced: forced)])
        #expect(harness.send(.followDue(follow1, execute: true)) == [.scrollToEnd])
        if !parentFirst {
            #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery2)])
        }
        let cancellations: [Effect] = parentFirst
            ? [.cancelFollowTask(follow1)]
            : [.cancelFollowTask(follow1), .cancelRecoveryTask(recovery2)]
        #expect(harness.send(.viewDisappeared) == cancellations)
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.state == State(nextTokenId: parentFirst ? 2 : 3))
        #expect(harness.liveFollows.isEmpty)
        #expect(harness.liveRecoveries.isEmpty)
        #expect(harness.send(.viewDisappeared).isEmpty)
        expectIgnored(lateLifecycleEvents(follow: follow1, recovery: recovery2), by: &harness)
        #expect(harness.scrolls == 1)
        #expect(harness.rePins == 0)
        #expect(harness.goToEndShown == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func disappearanceCancelsPollingAndOwningRecovery(parentFirst: Bool, correcting: Bool) {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        if correcting {
            #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
            #expect(harness.state.owner == .recovery(recovery1))
        } else {
            #expect(harness.state.armedRecovery == .polling(recovery1))
        }
        #expect(harness.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        if !parentFirst { #expect(harness.send(.endDerealized).isEmpty) }
        #expect(harness.send(.viewDisappeared) == [.cancelRecoveryTask(recovery1)])
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.state == State(nextTokenId: 2))
        #expect(harness.liveRecoveries.isEmpty)
        expectIgnored(lateLifecycleEvents(follow: staleFollow, recovery: recovery1), by: &harness)
        #expect(harness.pageUps == (correcting ? [1600] : []))
        #expect(harness.scrolls == 0)
        #expect(harness.outcomes.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func disappearanceCancelsFollowBeforePollingOrDemotedRecovery(forced: Bool, parentFirst: Bool) {
        for correcting in [false, true] {
            var harness = makeHarness()
            #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
            if correcting {
                #expect(harness.send(.recoveryStep(recovery1, .recover(pageOffsetY: 1600))) == [LogLine.pageUp, .pageUp(offsetY: 1600)])
            }
            #expect(harness.send(.followRequested(forced: forced)) == [.startFollowTask(follow2, forced: forced)])
            #expect(harness.state.armedRecovery == (correcting ? .demoted(recovery1) : .polling(recovery1)))
            #expect(harness.send(.endRealized(userIsScrolledAway: false)).isEmpty)
            if !parentFirst { #expect(harness.send(.endDerealized).isEmpty) }
            #expect(harness.send(.viewDisappeared) == [.cancelFollowTask(follow2), .cancelRecoveryTask(recovery1)])
            #expect(harness.send(.endDerealized).isEmpty)
            #expect(harness.state == State(nextTokenId: 3))
            #expect(harness.liveFollows.isEmpty)
            #expect(harness.liveRecoveries.isEmpty)
            expectIgnored(lateLifecycleEvents(follow: follow2, recovery: recovery1), by: &harness)
            #expect(harness.pageUps == (correcting ? [1600] : []))
            #expect(harness.scrolls == 0)
            #expect(harness.rePins == 0)
            #expect(harness.outcomes.isEmpty)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func disappearanceClearsATransferredGiveUpWithoutShowingIt(forced: Bool, parentFirst: Bool) {
        var harness = transferredGiveUp(forced: forced)
        if !parentFirst {
            #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery3)])
        }
        let cancellations: [Effect] = parentFirst
            ? [.cancelFollowTask(follow2)]
            : [.cancelFollowTask(follow2), .cancelRecoveryTask(recovery3)]
        #expect(harness.send(.viewDisappeared) == cancellations)
        #expect(harness.send(.endDerealized).isEmpty)
        #expect(harness.state == State(nextTokenId: parentFirst ? 3 : 4))
        #expect(harness.liveFollows.isEmpty)
        #expect(harness.liveRecoveries.isEmpty)
        expectIgnored(lateLifecycleEvents(follow: follow2, recovery: recovery1), by: &harness)
        expectIgnored(lateLifecycleEvents(follow: follow2, recovery: recovery3), by: &harness)
        let nextRecovery = RecoveryToken(id: harness.state.nextTokenId)
        #expect(harness.send(.viewAppeared) == [.startRecoveryTask(nextRecovery)])
        expectIgnored(lateLifecycleEvents(follow: follow2, recovery: recovery1), by: &harness)
        #expect(harness.state.fallback == .none)
        #expect(harness.goToEndShown == 0)
        #expect(harness.outcomes == [.recordRecoveryOutcome(.giveUp, corrections: 0)])
        #expect(harness.scrolls == 0)
        #expect(harness.rePins == 0)
    }

    func makeInactiveHarness() -> LifecycleHarness {
        LifecycleHarness(state: State(), userIsScrolledAway: false, check: checkInvariants)
    }

    /// Continuations and all terminal outcomes from cancelled tasks.
    func lateLifecycleEvents(follow: FollowToken, recovery: RecoveryToken) -> [Event] {
        [
            .followDue(follow, execute: false), .followDue(follow, execute: true),
            .followFinished(follow, .executed(nil)), .followFinished(follow, .executed(.landed)),
            .followFinished(follow, .executed(.giveUp)), .followFinished(follow, .dropped),
            .followFinished(follow, .yielded), .followFinished(follow, .cancelled), .followFinished(follow, .replaced),
            .recoveryStep(recovery, .settling), .recoveryStep(recovery, .followToEnd),
            .recoveryStep(recovery, .recover(pageOffsetY: blank.contentOffsetY - blank.containerHeight)),
            .recoveryPagedUp(recovery, mayFollowBack: false), .recoveryPagedUp(recovery, mayFollowBack: true),
            .recoveryFinished(recovery, .giveUp, corrections: 2), .recoveryFinished(recovery, .notNeeded, corrections: 1),
            .recoveryFinished(recovery, .yieldToUser, corrections: 1)
        ]
    }

    func expectIgnored(_ events: [Event], by harness: inout LifecycleHarness, sourceLocation: SourceLocation = #_sourceLocation) {
        let before = harness.state
        for event in events {
            #expect(harness.send(event, sourceLocation: sourceLocation).isEmpty, "\(event)", sourceLocation: sourceLocation)
            #expect(harness.state == before, "\(event)", sourceLocation: sourceLocation)
        }
    }
}
