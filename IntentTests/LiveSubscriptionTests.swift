@testable import Intent
import Testing

/// Transitions of the shared live-subscription state used by the per-workspace stores.
@MainActor
struct LiveSubscriptionTests {
    @Test func idleHasNoIdAndIsNeitherLiveNorResnapshotting() {
        let state = LiveSubscription.idle
        #expect(state.id == nil)
        #expect(!state.isLive)
        #expect(!state.isResnapshotting)
    }

    @Test func subscribeThenSnapshotGoesLive() {
        var state = LiveSubscription.idle
        let previous = state.acknowledge("sub-1")
        #expect(previous == nil)
        #expect(state == .subscribed(id: "sub-1"))
        #expect(!state.isLive)

        state.applySnapshot()
        #expect(state == .live(id: "sub-1"))
        #expect(state.isLive)
        #expect(state.id == "sub-1")
    }

    @Test func snapshotBeforeAcknowledgementIsLiveWithoutId() {
        var state = LiveSubscription.idle
        state.applySnapshot()
        #expect(state == .live(id: nil))

        let previous = state.acknowledge("sub-1")
        #expect(previous == nil)
        #expect(state == .live(id: "sub-1"), "An ack keeps the list live")
    }

    @Test func acknowledgeReturnsThePreviousIdEvenWhenItRepeats() {
        var state = LiveSubscription.live(id: "sub-1")
        let repeated = state.acknowledge("sub-1")
        #expect(repeated == "sub-1")
        #expect(state == .live(id: "sub-1"))
        let replaced = state.acknowledge("sub-2")
        #expect(replaced == "sub-1")
        #expect(state == .live(id: "sub-2"))
    }

    @Test func subscribeFailureFallsBackToLegacy() {
        var live = LiveSubscription.live(id: "sub-1")
        live.subscribeFailed()
        #expect(live == .idle)

        var resnapshotting = LiveSubscription.resnapshotting(id: "sub-1", feed: .live)
        resnapshotting.subscribeFailed()
        #expect(resnapshotting == .resnapshotting(id: nil, feed: .legacy))
    }

    @Test func clearIdKeepsTheFeed() {
        var subscribed = LiveSubscription.subscribed(id: "sub-1")
        subscribed.clearId()
        #expect(subscribed == .idle)

        var live = LiveSubscription.live(id: "sub-1")
        live.clearId()
        #expect(live == .live(id: nil))
    }

    @Test func gapStartsOneResnapshotAndKeepsTheFeedUntilItBegins() {
        var state = LiveSubscription.live(id: "sub-1")
        let started = state.requestResnapshot()
        #expect(started)
        #expect(state == .resnapshotting(id: "sub-1", feed: .live))
        #expect(state.isLive)
        let startedAgain = state.requestResnapshot()
        #expect(!startedAgain, "A second gap does not start another resnapshot")

        state.beginResnapshot()
        #expect(state == .resnapshotting(id: "sub-1", feed: .legacy))
        #expect(!state.isLive)
        #expect(state.isResnapshotting)
    }

    @Test func gapBeforeSnapshotStartsAResnapshot() {
        var state = LiveSubscription.subscribed(id: "sub-1")
        let started = state.requestResnapshot()
        #expect(started)
        #expect(state == .resnapshotting(id: "sub-1", feed: .legacy))
    }

    @Test func fullResnapshotCycleEndsLiveOnTheNewSubscription() {
        var state = LiveSubscription.live(id: "sub-1")
        state.beginResnapshot()
        #expect(state.id == "sub-1", "The old id stays while its unsubscribe is in flight")

        state.clearId()
        #expect(state == .resnapshotting(id: nil, feed: .legacy))

        let previous = state.acknowledge("sub-2")
        #expect(previous == nil)
        #expect(state == .resnapshotting(id: "sub-2", feed: .legacy))

        state.applySnapshot()
        #expect(state == .resnapshotting(id: "sub-2", feed: .live))
        let startedDuringRefetch = state.requestResnapshot()
        #expect(!startedDuringRefetch, "Gaps stay ignored until the baseline refetch ends")

        state.endResnapshot()
        #expect(state == .live(id: "sub-2"))
    }

    @Test func endResnapshotSettlesEachFeed() {
        var withoutSnapshot = LiveSubscription.resnapshotting(id: "sub-2", feed: .legacy)
        withoutSnapshot.endResnapshot()
        #expect(withoutSnapshot == .subscribed(id: "sub-2"))

        var failed = LiveSubscription.resnapshotting(id: nil, feed: .legacy)
        failed.endResnapshot()
        #expect(failed == .idle)
    }

    @Test func endResnapshotAfterTeardownIsANoOp() {
        var state = LiveSubscription.resnapshotting(id: "sub-1", feed: .legacy)
        let releasedId = state.reset()
        #expect(releasedId == "sub-1")
        let previous = state.acknowledge("sub-2")
        #expect(previous == nil)

        state.endResnapshot()
        #expect(state == .subscribed(id: "sub-2"))
    }

    @Test func resetReturnsTheIdFromEveryState() {
        let states: [(LiveSubscription, String?)] = [
            (.idle, nil),
            (.subscribed(id: "a"), "a"),
            (.live(id: "b"), "b"),
            (.live(id: nil), nil),
            (.resnapshotting(id: "c", feed: .live), "c"),
            (.resnapshotting(id: nil, feed: .legacy), nil)
        ]
        for (start, expectedId) in states {
            var state = start
            let releasedId = state.reset()
            #expect(releasedId == expectedId)
            #expect(state == .idle)
        }
    }
}
