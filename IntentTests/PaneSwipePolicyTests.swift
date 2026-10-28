import Foundation
@testable import Intent
import Testing

struct PaneSwipePolicyTests {
    @Test func flicksCommitInTheirDirection() {
        #expect(PaneSwipePolicy.outcome(translation: 10, velocity: PaneSwipePolicy.commitVelocity) == .back)
        #expect(PaneSwipePolicy.outcome(translation: -10, velocity: -PaneSwipePolicy.commitVelocity) == .forward)
    }

    @Test func slowDragsNeedDistanceAndMustNotReverse() {
        let distance = PaneSwipePolicy.commitDistance
        #expect(PaneSwipePolicy.outcome(translation: distance - 1, velocity: 0) == .none)
        #expect(PaneSwipePolicy.outcome(translation: distance, velocity: 0) == .back)
        #expect(PaneSwipePolicy.outcome(translation: -distance, velocity: 0) == .forward)
        #expect(PaneSwipePolicy.outcome(translation: distance, velocity: -1) == .none)
        #expect(PaneSwipePolicy.outcome(translation: -distance, velocity: 1) == .none)
    }

    @Test func dragHintIsBounded() {
        #expect(PaneSwipePolicy.resistedOffset(for: 10_000) == -PaneSwipePolicy.resistedOffset(for: -10_000))
        #expect(PaneSwipePolicy.resistedOffset(for: 10_000) < 10_000)
    }
}
