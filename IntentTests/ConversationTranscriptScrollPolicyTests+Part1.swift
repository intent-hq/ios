import Foundation
@testable import Intent
import Testing
import UIKit

private let kTestAtBottomThreshold: CGFloat = 50

extension ConversationTranscriptScrollPolicyTests {
    private func rePinOnContainerChange(
        from oldHeight: CGFloat,
        to newHeight: CGFloat,
        isInteracting: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> ContainerRePin {
        ConversationTranscriptScrollPolicy.containerHeightChangeDecision(
            oldContainerHeight: oldHeight,
            newContainerHeight: newHeight,
            isInteracting: isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    private func deferredContainerRePin(
        distanceToBottom: CGFloat?,
        isInteracting: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> ContainerRePin {
        ConversationTranscriptScrollPolicy.deferredContainerRePinDecision(
            distanceToBottom: distanceToBottom,
            isInteracting: isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            driftTolerance: 1,
            atBottomThreshold: kTestAtBottomThreshold
        )
    }

    /// Regression (#272): a footer row appearing under the transcript shrank
    /// the container (simulator: 757.7 → 677.3 for an 80 pt row) while
    /// `contentOffset` stayed put, so the geometry read 80 pt from the bottom
    /// and Go to End appeared instead of the transcript staying at the end.
    @Test func containerShrinkWhilePinnedRePinsToBottom() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1968,
            contentOffsetY: 1188,
            containerHeight: 780
        ) == 0)
        let shrunk = ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1968,
            contentOffsetY: 1188,
            containerHeight: 700
        )
        #expect(shrunk == 80)
        #expect(ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: shrunk))
        #expect(rePinOnContainerChange(from: 780, to: 700) == .rePin)
    }

    /// The row disappearing grows the container back; a pinned viewport is
    /// re-pinned the other way rather than left past the end.
    @Test func containerGrowthWhilePinnedRePinsToBottom() {
        #expect(rePinOnContainerChange(from: 700, to: 780) == .rePin)
    }

    /// Under the finger the re-pin would fight the pan; a fling released just
    /// before the row lands is still decelerating (the bounce back included)
    /// while the scrolled-away flag has not crossed the threshold yet, and the
    /// re-pin would snap it back. Both defer to the settle re-check instead,
    /// as the #271 past-end clamp does.
    @Test func containerChangeWhileInteractingIsDeferred() {
        #expect(rePinOnContainerChange(from: 780, to: 700, isInteracting: true) == .deferred)
        #expect(rePinOnContainerChange(from: 700, to: 780, isInteracting: true) == .deferred)
        #expect(rePinOnContainerChange(from: 780, to: 700, isInteracting: false) == .rePin)
    }

    /// A 36 pt hooks row landing during the bounce back leaves the settled
    /// viewport 36 pt short of the bottom: under the threshold, so no Go to
    /// End and no further edge to close the gap — the settle re-check does.
    /// Still interacting it waits again; a viewport that already rests at
    /// the bottom, or that the fling carried past the threshold (its edge
    /// applied on the way), is left where it is.
    @Test func deferredContainerRePinFollowsOnSettleWithinBottomBand() {
        #expect(deferredContainerRePin(distanceToBottom: 36) == .rePin)
        #expect(deferredContainerRePin(distanceToBottom: 36, isInteracting: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 0) == .none)
        #expect(deferredContainerRePin(distanceToBottom: -80) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 400) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 36, userIsScrolledAway: true) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 36, hasInitiallyScrolled: false) == .none)
        #expect(deferredContainerRePin(distanceToBottom: nil) == .none)
    }

    /// Scrolled away, the container resizes at its bottom edge and the content
    /// under the reader does not move (observed in the simulator: the anchored
    /// row kept its frame across both edges), so nothing is adjusted.
    @Test func containerChangeWhileScrolledAwayLeavesContentInPlace() {
        #expect(rePinOnContainerChange(from: 780, to: 700, userIsScrolledAway: true) == .none)
        #expect(rePinOnContainerChange(from: 700, to: 780, userIsScrolledAway: true) == .none)
        #expect(rePinOnContainerChange(
            from: 780,
            to: 700,
            isInteracting: true,
            userIsScrolledAway: true
        ) == .none)
    }

    @Test func unchangedContainerNeverRePins() {
        #expect(rePinOnContainerChange(from: 780, to: 780) == .none)
        #expect(rePinOnContainerChange(from: 780, to: 780, isInteracting: true) == .none)
        #expect(rePinOnContainerChange(from: 780, to: 780, userIsScrolledAway: true) == .none)
    }

    /// Before the entry scroll the viewport is not following yet; the entry
    /// scroll decides where it lands.
    @Test func containerChangeBeforeEntryScrollIsIgnored() {
        #expect(rePinOnContainerChange(from: 780, to: 700, hasInitiallyScrolled: false) == .none)
        #expect(rePinOnContainerChange(
            from: 780,
            to: 700,
            hasInitiallyScrolled: false,
            userIsScrolledAway: true
        ) == .none)
    }

    private typealias BottomBandRePin = ConversationTranscriptScrollPolicy.BottomBandRePinDecision

    private func recheckBottomBandAfterEdge(
        geometryAway: Bool = false,
        isInteracting: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldRecheckBottomBandAfterEdge(
            geometryAway: geometryAway,
            isInteracting: isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    private func bottomBandRePin(
        distanceToBottom: CGFloat?,
        isInteracting: Bool = false,
        isFollowing: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> BottomBandRePin {
        ConversationTranscriptScrollPolicy.bottomBandRePinDecision(
            distanceToBottom: distanceToBottom,
            isInteracting: isInteracting,
            isFollowing: isFollowing,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            driftTolerance: 1,
            atBottomThreshold: 50
        )
    }

    /// Regression (#346): a new conversation's transcript grows from shorter
    /// than the container (a negative distance) past one page, and the band
    /// observer delivers the crossing into band 0 reading within the band.
    /// On a pinned, settled transcript that edge schedules the settle
    /// re-check; an away edge is content growth that
    /// `shouldRePinAfterContentGrowth` re-pins at once.
    @Test func withinBandEdgeOnPinnedSettledTranscriptSchedulesRecheck() {
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: -120) == -3)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 32) == 0)
        #expect(recheckBottomBandAfterEdge())
        #expect(!recheckBottomBandAfterEdge(geometryAway: true))
    }

    /// Not under the finger (a gesture, not growth), not before the entry
    /// scroll has decided, and not for a reader who scrolled away. A follow
    /// in flight is not a reason to drop the request: the last rows can lay
    /// out during its completion window and its drain re-pins only on an
    /// away edge, so the edge still schedules and the settle re-check defers
    /// (`bottomBandRePinDecision`) until the follow lands.
    @Test func withinBandEdgeRecheckYieldsToGesturesAndTheEntryDecision() {
        #expect(!recheckBottomBandAfterEdge(isInteracting: true))
        #expect(!recheckBottomBandAfterEdge(hasInitiallyScrolled: false))
        #expect(!recheckBottomBandAfterEdge(userIsScrolledAway: true))
    }

    /// Settled, pinned and resting a line or two short of the end — 32 pt in
    /// the report, under the threshold so Go to End stays hidden — the
    /// viewport is followed to the bottom. A rest within the drift tolerance
    /// is layout rounding; content still shorter than the container rests at
    /// a negative distance; past the threshold the away edge owns it; an
    /// unknown distance proves nothing.
    @Test func bottomBandRePinFollowsOnSettleWithinBand() {
        #expect(bottomBandRePin(distanceToBottom: 32) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 2) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 50) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 1) == .none)
        #expect(bottomBandRePin(distanceToBottom: 0) == .none)
        #expect(bottomBandRePin(distanceToBottom: -120) == .none)
        #expect(bottomBandRePin(distanceToBottom: 51) == .none)
        #expect(bottomBandRePin(distanceToBottom: 400) == .none)
        #expect(bottomBandRePin(distanceToBottom: nil) == .none)
    }

    /// Still interacting, or with a follow in flight the re-pin would land
    /// under, the re-check waits again; scrolled away or before the entry
    /// scroll nothing is following, whatever the gesture state.
    @Test func bottomBandRePinDefersWhileInteractingOrFollowing() {
        #expect(bottomBandRePin(distanceToBottom: 32, isInteracting: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: 32, isFollowing: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: 0, isInteracting: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: nil, isFollowing: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: 32, userIsScrolledAway: true) == .none)
        #expect(bottomBandRePin(distanceToBottom: 32, hasInitiallyScrolled: false) == .none)
        #expect(bottomBandRePin(distanceToBottom: 32, isInteracting: true, userIsScrolledAway: true) == .none)
        #expect(bottomBandRePin(distanceToBottom: 32, isFollowing: true, hasInitiallyScrolled: false) == .none)
    }

    @Test func followsOnlyAfterEntryScrollWhileAtBottom() {
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: false,
            userIsScrolledAway: false
        ))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: true,
            userIsScrolledAway: false
        ))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: true,
            userIsScrolledAway: true
        ))
    }

    /// #280: the observed geometry changes at every band crossing so a flag
    /// edge the observer drops is re-delivered within one band of travel;
    /// the band is sized to the at-bottom threshold.
    @Test func distanceBandStepsAtEveryThreshold() {
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 0, bandHeight: 50) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 46.7, bandHeight: 50) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 52.7, bandHeight: 50) == 1)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 172.7, bandHeight: 50) == 3)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 210, bandHeight: 50) == 4)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: -10, bandHeight: 50) == -1)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 120)
            == ConversationTranscriptScrollPolicy.distanceBand(
                distanceToBottom: 120,
                bandHeight: Constants.Conversation.Transcript.atBottomThreshold
            ))
    }

    /// #280: a geometry edge clearing the flag (the viewport already at the
    /// bottom, or a transient mid-drag reading) must not start a forced scroll;
    /// only the Go to End tap, which records its request first, does.
    @Test func scrolledAwayClearedFollowsOnlyFromGoToEnd() {
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: true
        ))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: false
        ))
    }

    /// Ordered regression: a user append raises a forced follow; during its
    /// debounce the user drags away (edge with gesture → away), then a row
    /// re-measures and reads at-bottom for one pass (edge → pinned, #280).
    /// The cleared flag is not a Go to End request, so no second forced
    /// follow is queued, and the one in flight yields at execution instead of
    /// scrolling against the pan.
    @Test func transientAtBottomEdgeMidDragDoesNotRequeueOrExecuteForcedFollow() {
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(!transition(current: true, distanceToBottom: 10, isInteracting: true))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: false
        ))
        #expect(!executeFollow(forced: true, userIsScrolledAway: false, distanceToBottom: 10, isInteracting: true))
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
    }

    @Test func streamingStartScrollsOnlyWhileFollowing() {
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true,
            hasInitiallyScrolled: true,
            userIsScrolledAway: false
        ))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true,
            hasInitiallyScrolled: true,
            userIsScrolledAway: true
        ))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true,
            hasInitiallyScrolled: false,
            userIsScrolledAway: false
        ))
    }

    @Test func streamingEndNeverScrolls() {
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: false,
            hasInitiallyScrolled: true,
            userIsScrolledAway: false
        ))
    }

    func streamingDelta(
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false,
        distanceToBottom: CGFloat? = 20,
        now: TimeInterval = 10,
        lastFollowAt: TimeInterval? = nil
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldFollowStreamingDelta(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            distanceToBottom: distanceToBottom,
            now: now,
            lastFollowAt: lastFollowAt,
            driftTolerance: 1,
            atBottomThreshold: kTestAtBottomThreshold,
            minimumInterval: 0.5
        )
    }

    @Test func streamingDeltaNeverScrollsWhilePinnedAtBottom() {
        #expect(!streamingDelta(distanceToBottom: 0))
        #expect(!streamingDelta(distanceToBottom: 1))
        #expect(!streamingDelta(distanceToBottom: -30))
    }

    @Test func streamingDeltaRePinsDriftedViewport() {
        #expect(streamingDelta(distanceToBottom: 2))
        #expect(streamingDelta(distanceToBottom: 40))
    }

    @Test func streamingDeltaHonorsFollowGates() {
        #expect(!streamingDelta(hasInitiallyScrolled: false))
        #expect(!streamingDelta(userIsScrolledAway: true, distanceToBottom: 400))
    }

    /// `userIsScrolledAway` lags the geometry; a live distance past the
    /// at-bottom band is treated as scrolled away even while the flag is false.
    @Test func streamingDeltaStaysInsideAtBottomBand() {
        #expect(streamingDelta(distanceToBottom: 50))
        #expect(!streamingDelta(distanceToBottom: 51))
        #expect(!streamingDelta(distanceToBottom: 400))
    }

    @Test func streamingDeltaSkipsUntilScrollViewIsFound() {
        #expect(!streamingDelta(distanceToBottom: nil))
    }

    @Test func streamingDeltaIsRateLimitedToOneScrollPerInterval() {
        #expect(streamingDelta(now: 10, lastFollowAt: nil))
        #expect(!streamingDelta(now: 10, lastFollowAt: 10))
        #expect(!streamingDelta(now: 10.49, lastFollowAt: 10))
        #expect(streamingDelta(now: 10.5, lastFollowAt: 10))
        #expect(streamingDelta(now: 12, lastFollowAt: 10))
    }
}
