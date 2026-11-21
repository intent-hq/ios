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
        recoveryOwnsViewport: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> ContainerRePin {
        ConversationTranscriptScrollPolicy.containerHeightChangeDecision(
            oldContainerHeight: oldHeight,
            newContainerHeight: newHeight,
            isInteracting: isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            recoveryOwnsViewport: recoveryOwnsViewport
        )
    }

    private func deferredContainerRePin(
        distanceToBottom: CGFloat?,
        isInteracting: Bool = false,
        isFollowing: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> ContainerRePin {
        ConversationTranscriptScrollPolicy.deferredContainerRePinDecision(
            distanceToBottom: distanceToBottom,
            isInteracting: isInteracting,
            isFollowing: isFollowing,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            driftTolerance: 1,
            atBottomThreshold: kTestAtBottomThreshold
        )
    }

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

    @Test func containerGrowthWhilePinnedRePinsToBottom() {
        #expect(rePinOnContainerChange(from: 700, to: 780) == .rePin)
    }

    @Test func containerChangeWhileInteractingIsDeferred() {
        #expect(rePinOnContainerChange(from: 780, to: 700, isInteracting: true) == .deferred)
        #expect(rePinOnContainerChange(from: 700, to: 780, isInteracting: true) == .deferred)
        #expect(rePinOnContainerChange(from: 780, to: 700, isInteracting: false) == .rePin)
    }

    @Test func containerChangeWhileRecoveryOwnsViewportIsDeferred() {
        #expect(rePinOnContainerChange(from: 780, to: 700, recoveryOwnsViewport: true) == .deferred)
        #expect(rePinOnContainerChange(from: 700, to: 780, recoveryOwnsViewport: true) == .deferred)
        #expect(rePinOnContainerChange(from: 780, to: 700, recoveryOwnsViewport: false) == .rePin)
    }

    @Test func deferredContainerChangeWaitsForRecoveryToReleaseViewport() {
        #expect(rePinOnContainerChange(from: 780, to: 700, recoveryOwnsViewport: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 590, isFollowing: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 590, isFollowing: false) == .rePin)
    }

    @Test func recoveryOwnershipDoesNotPinUnchangedOrUnfollowedContainers() {
        #expect(rePinOnContainerChange(from: 780, to: 780, recoveryOwnsViewport: true) == .none)
        #expect(rePinOnContainerChange(
            from: 780, to: 700, recoveryOwnsViewport: true, userIsScrolledAway: true
        ) == .none)
        #expect(rePinOnContainerChange(
            from: 780, to: 700, recoveryOwnsViewport: true, hasInitiallyScrolled: false
        ) == .none)
    }

    @Test func deferredContainerRePinFollowsOnSettleWithinBottomBand() {
        #expect(deferredContainerRePin(distanceToBottom: 36) == .follow)
        #expect(deferredContainerRePin(distanceToBottom: 36, isInteracting: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 36, isFollowing: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 36, isFollowing: true, userIsScrolledAway: true) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 0) == .none)
        #expect(deferredContainerRePin(distanceToBottom: -80) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 36, userIsScrolledAway: true) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 36, hasInitiallyScrolled: false) == .none)
        #expect(deferredContainerRePin(distanceToBottom: nil) == .none)
    }

    @Test func deferredContainerRePinPinsBackAViewportTheResizeDisplaced() {
        #expect(deferredContainerRePin(distanceToBottom: 400) == .rePin)
        #expect(deferredContainerRePin(distanceToBottom: 12_000) == .rePin)
        #expect(deferredContainerRePin(distanceToBottom: kTestAtBottomThreshold) == .follow)
        #expect(deferredContainerRePin(distanceToBottom: 400, isInteracting: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 400, isFollowing: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 400, userIsScrolledAway: true) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 400, hasInitiallyScrolled: false) == .none)
    }

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
        isInteracting: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldRecheckBottomBandAfterEdge(
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
            driftTolerance: 1
        )
    }

    @Test func withinBandEdgeOnPinnedSettledTranscriptSchedulesRecheck() {
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: -120) == -3)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 32) == 0)
        #expect(ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: 112))
        #expect(recheckBottomBandAfterEdge())
    }

    @Test func withinBandEdgeRecheckYieldsToGesturesAndTheEntryDecision() {
        #expect(!recheckBottomBandAfterEdge(isInteracting: true))
        #expect(!recheckBottomBandAfterEdge(hasInitiallyScrolled: false))
        #expect(!recheckBottomBandAfterEdge(userIsScrolledAway: true))
    }

    @Test func bottomBandRePinFollowsOnSettleWithinBand() {
        #expect(bottomBandRePin(distanceToBottom: 32) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 2) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 50) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 51) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 112) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 400) == .rePin)
        #expect(bottomBandRePin(distanceToBottom: 1) == .none)
        #expect(bottomBandRePin(distanceToBottom: 0) == .none)
        #expect(bottomBandRePin(distanceToBottom: -1) == .none)
        #expect(bottomBandRePin(distanceToBottom: -120) == .none)
        #expect(bottomBandRePin(distanceToBottom: nil) == .none)
    }

    @Test func bottomBandRePinDefersWhileInteractingOrFollowing() {
        #expect(bottomBandRePin(distanceToBottom: 32, isInteracting: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: 32, isFollowing: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: 0, isInteracting: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: nil, isFollowing: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: 112, isFollowing: true) == .deferred)
        #expect(bottomBandRePin(distanceToBottom: 32, userIsScrolledAway: true) == .none)
        #expect(bottomBandRePin(distanceToBottom: 112, userIsScrolledAway: true) == .none)
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

    @Test func scrolledAwayClearedFollowsOnlyFromGoToEnd() {
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: true
        ))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: false
        ))
    }

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
