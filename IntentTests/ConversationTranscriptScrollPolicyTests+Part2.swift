import Foundation
@testable import Intent
import Testing
import UIKit

private let kTestAtBottomThreshold: CGFloat = 50

extension ConversationTranscriptScrollPolicyTests {
    func executeFollow(
        forced: Bool = false,
        userIsScrolledAway: Bool = false,
        distanceToBottom: CGFloat? = 20,
        isInteracting: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldExecuteFollow(
            forced: forced,
            userIsScrolledAway: userIsScrolledAway,
            distanceToBottom: distanceToBottom,
            isInteracting: isInteracting,
            driftTolerance: 1,
            atBottomThreshold: kTestAtBottomThreshold
        )
    }

    /// Regression: a drifted delta requests a follow, then the user scrolls
    /// away during the debounce; the delayed execution must not snap back,
    /// whether the flag has caught up or only the live distance shows it.
    @Test func automaticFollowIsDroppedWhenUserScrolledAwayDuringDebounce() {
        #expect(streamingDelta(distanceToBottom: 20))
        #expect(!executeFollow(userIsScrolledAway: true, distanceToBottom: 400))
        #expect(!executeFollow(userIsScrolledAway: true, distanceToBottom: nil))
        #expect(!executeFollow(userIsScrolledAway: false, distanceToBottom: 400))
    }

    @Test func automaticFollowExecutesOnlyInsideAtBottomBand() {
        #expect(executeFollow(distanceToBottom: 50))
        #expect(!executeFollow(distanceToBottom: 51))
    }

    /// Regression: the viewport re-pinned on its own (bottom anchor) while the
    /// follow was debouncing; there is nothing left to scroll.
    @Test func automaticFollowIsDroppedWhenAlreadyPinnedAtExecution() {
        #expect(streamingDelta(distanceToBottom: 20))
        #expect(!executeFollow(distanceToBottom: 0))
        #expect(!executeFollow(distanceToBottom: 1))
        #expect(!executeFollow(distanceToBottom: -30))
        #expect(executeFollow(distanceToBottom: 2))
        #expect(executeFollow(distanceToBottom: nil))
    }

    /// A forced follow is requested pinned, so at execution it lands unless
    /// the user took over meanwhile: a gesture in progress, or one that
    /// already ended having set the flag.
    @Test func forcedFollowExecutesUnlessUserTookOver() {
        #expect(executeFollow(forced: true, distanceToBottom: 400))
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(executeFollow(forced: true, distanceToBottom: nil))
        #expect(!executeFollow(forced: true, distanceToBottom: 400, isInteracting: true))
        #expect(!executeFollow(forced: true, distanceToBottom: 0, isInteracting: true))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 400))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: nil))
    }

    /// Ordered regression: a user append raises a forced follow while pinned;
    /// during its debounce the user drags away and the gesture ends (phase
    /// final sample with the gesture → away) before the follow comes due. The
    /// view cancels the pending follow the moment the gesture is observed
    /// (see `gestureObservedWhileForcedFollowPendingCancelsItImmediately`);
    /// should the task still reach execution or a landing poll first, the
    /// raised flag makes it yield instead of snapping the user back. The viewport stays
    /// away with Go to End showing, nothing re-queues the follow (the flag is
    /// not a Go to End request), and a later Go to End tap is a fresh request.
    @Test func gestureThatEndedAwayDuringForcedFollowDebounceWins() {
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(transition(current: true, distanceToBottom: 300, isInteracting: false))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 300))
        #expect(landing(geometry(offsetY: 0), userIsScrolledAway: true) == .yieldToUser)
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: false
        ))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 300, isInteracting: true))
        #expect(!rePinAfterGrowth(isFollowing: false, userIsScrolledAway: true))
        #expect(transition(current: true, distanceToBottom: 300, isInteracting: false))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: true
        ))
        #expect(executeFollow(forced: true, userIsScrolledAway: false, distanceToBottom: 300))
    }

    private func takesOver(isInteracting: Bool, isFollowing: Bool) -> Bool {
        ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
            isInteracting: isInteracting,
            isFollowing: isFollowing
        )
    }

    private func latch(distanceToBottom: CGFloat, isInteracting: Bool, current: Bool = true) -> Bool {
        ConversationTranscriptScrollPolicy.forcedFollowTakeoverLatch(
            current: current,
            geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: distanceToBottom,
                atBottomThreshold: kTestAtBottomThreshold
            ),
            isInteracting: isInteracting
        )
    }

    private func honorForced(takenOver: Bool) -> Bool {
        ConversationTranscriptScrollPolicy.shouldHonorForcedFollow(takenOverByGesture: takenOver)
    }

    /// Ordered regression: a forced follow is pending (debounce or landing
    /// loop) when a user gesture is observed — a user-driven phase beginning,
    /// or a geometry edge under UIKit tracking. The follow is taken over and
    /// cancelled at that moment; the gesture then drags away, its final away
    /// edge is dropped by the band observer, and the phase ends (its sample
    /// arriving as "away") before the follow would have come due. Nothing is
    /// left to execute or land, so no scroll is issued; the phase sample
    /// raises the flag and Go to End shows. The takeover is latched, so the
    /// thinking indicator appearing meanwhile does not revive the follow;
    /// Go to End tapped afterwards is a fresh request that clears the latch.
    @Test func gestureObservedWhileForcedFollowPendingCancelsItImmediately() {
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(takesOver(isInteracting: true, isFollowing: true))
        #expect(!takesOver(isInteracting: false, isFollowing: true))
        #expect(!takesOver(isInteracting: true, isFollowing: false))
        // Mid-gesture edges within the threshold keep the pin and the latch.
        #expect(!transition(current: false, distanceToBottom: 20, isInteracting: true))
        #expect(latch(distanceToBottom: 20, isInteracting: true))
        // The final away edge is dropped; the phase ending is the sample.
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(latch(distanceToBottom: 300, isInteracting: false))
        #expect(!honorForced(takenOver: true))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true,
            hasInitiallyScrolled: true,
            userIsScrolledAway: true
        ))
        #expect(!rePinAfterGrowth(isFollowing: false, userIsScrolledAway: true))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: true
        ))
        #expect(honorForced(takenOver: false))
        #expect(executeFollow(forced: true, distanceToBottom: 300))
    }

    /// The latch releases only once the viewport rests within the threshold
    /// with no gesture in progress: a gesture that ends pinned, or drags back
    /// and lifts, hands the transcript back to content-raised forced follows.
    @Test func forcedFollowTakeoverLatchReleasesWhenTheGestureRestsPinned() {
        #expect(latch(distanceToBottom: 300, isInteracting: true))
        #expect(latch(distanceToBottom: 300, isInteracting: false))
        #expect(latch(distanceToBottom: 0, isInteracting: true))
        #expect(!latch(distanceToBottom: 0, isInteracting: false))
        #expect(!latch(distanceToBottom: 50, isInteracting: false))
        #expect(!latch(distanceToBottom: 300, isInteracting: true, current: false))
        #expect(honorForced(takenOver: false))
    }

    /// The forced-follow gesture predicate is the same one the geometry edges
    /// read: a SwiftUI scroll phase counts as interacting even when the finder
    /// has not resolved a UIScrollView and its flags read false.
    @Test func phaseOnlyInteractionYieldsForcedFollowAndLanding() {
        #expect(!executeFollow(forced: true, distanceToBottom: nil, isInteracting: true))
        #expect(landing(nil, isInteracting: true) == .yieldToUser)
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
    }

    /// Ordered regression: pinned, a streaming delta at distance 20 queues an
    /// automatic follow; during its debounce content grows to distance 100
    /// with no gesture. The growth edge keeps the pin but is not re-pinned
    /// while the follow is in flight; the follow is then dropped as outside
    /// the band. Reconciling the live distance once the follow has drained
    /// must re-pin, so the viewport does not rest short with Go to End hidden.
    @Test func pinnedGrowthDuringAutomaticFollowDebounceRePinsWhenTheFollowDrains() {
        #expect(streamingDelta(distanceToBottom: 20))
        #expect(!transition(current: false, distanceToBottom: 100, isInteracting: false))
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(!executeFollow(distanceToBottom: 100))
        #expect(rePinAfterGrowth(isFollowing: false))
        #expect(!rePinAfterGrowth(geometryAway: false, isFollowing: false))
        #expect(!rePinAfterGrowth(isInteracting: true, isFollowing: false))
    }

    typealias ViewportGeometry = ConversationTranscriptScrollPolicy.ViewportGeometry
    typealias LandingStep = ConversationTranscriptScrollPolicy.FollowLandingStep

    /// Geometry of a 1 000 pt transcript in a 700 pt viewport; `offsetY` is
    /// the resting offset (300 is the bottom).
}
