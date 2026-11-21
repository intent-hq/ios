import Foundation
@testable import Intent
import Testing
import UIKit

private let kTestAtBottomThreshold: CGFloat = 50

extension ConversationTranscriptScrollPolicyTests {
    @Test(arguments: [
        (CGFloat(-20), true), (0, true), (50, true), (699, true),
        (700, true), (701, false), (10_000, false)
    ])
    func goToEndAnimationIsLimitedToOneVisibleScreen(distance: CGFloat, animated: Bool) {
        let viewport = ConversationTranscriptScrollPolicy.ViewportGeometry(
            contentOffsetY: 10_000 + 80 - 800 - distance,
            contentHeight: 10_000,
            containerHeight: 800,
            topInset: 20,
            bottomInset: 80
        )
        #expect(ConversationTranscriptScrollPolicy.shouldAnimateGoToEnd(geometry: viewport) == animated)
    }

    @Test func goToEndKeepsAnimationUntilGeometryIsUsable() {
        #expect(ConversationTranscriptScrollPolicy.shouldAnimateGoToEnd(geometry: nil))
        for height: CGFloat in [0, 100, .infinity, .nan] {
            let viewport = ConversationTranscriptScrollPolicy.ViewportGeometry(
                contentOffsetY: 0, contentHeight: 10_000, containerHeight: height, topInset: 20, bottomInset: 80
            )
            #expect(ConversationTranscriptScrollPolicy.shouldAnimateGoToEnd(geometry: viewport))
        }
    }

    @Test(arguments: [false, true])
    func reduceMotionKeepsGoToEndAndFollowsInPlace(reduceMotion: Bool) {
        typealias Policy = ConversationTranscriptScrollPolicy
        #expect(Policy.goToEndVisibilityTransition(reduceMotion: reduceMotion) == (reduceMotion ? .fade : .slideAndFade))
        #expect(Policy.animatesFollow(requested: true, reduceMotion: reduceMotion) == !reduceMotion)
        #expect(!Policy.animatesFollow(requested: false, reduceMotion: reduceMotion))
    }

    @Test func transcriptViewAppliesReduceMotionPolicyToFollowsAndGoToEnd() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: TestSourceInputs.url(for: path), encoding: .utf8)
        }
        let dir = "Intent/Views/Conversation/Transcript/"
        let view = try source(dir + "ConversationTranscriptView.swift")
        #expect(view.contains("@Environment(\\.accessibilityReduceMotion) var reduceMotion"))

        let follow = try source(dir + "ConversationTranscriptView+Follow.swift")
        let send = try #require(follow.components(separatedBy: "func send(_ event: Lifecycle.Event").dropFirst().first)
            .components(separatedBy: "for effect in effects")[0]
        #expect(
            send.contains("let animated = ConversationTranscriptScrollPolicy.animatesFollow(requested: animated, reduceMotion: reduceMotion)"),
            "send() must apply Reduce Motion before any effect issues a scroll"
        )
        #expect(follow.contains("perform(effect, proxy: proxy, animated: animated)"))

        let presentation = try source(dir + "ConversationTranscriptView+Presentation.swift")
        #expect(presentation.contains(".transition(goToEndTransition)"))
        #expect(presentation.contains("ConversationTranscriptScrollPolicy.goToEndVisibilityTransition(reduceMotion: reduceMotion)"))
        #expect(!presentation.contains(".transition(.opacity.combined(with: .move(edge: .bottom)))"))
    }

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

    @Test func automaticFollowIsDroppedWhenAlreadyPinnedAtExecution() {
        #expect(streamingDelta(distanceToBottom: 20))
        #expect(!executeFollow(distanceToBottom: 0))
        #expect(!executeFollow(distanceToBottom: 1))
        #expect(!executeFollow(distanceToBottom: -30))
        #expect(executeFollow(distanceToBottom: 2))
        #expect(executeFollow(distanceToBottom: nil))
    }

    @Test func forcedFollowExecutesUnlessUserTookOver() {
        #expect(executeFollow(forced: true, distanceToBottom: 400))
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(executeFollow(forced: true, distanceToBottom: nil))
        #expect(!executeFollow(forced: true, distanceToBottom: 400, isInteracting: true))
        #expect(!executeFollow(forced: true, distanceToBottom: 0, isInteracting: true))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 400))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: nil))
    }

    @Test func gestureThatEndedAwayDuringForcedFollowDebounceWins() {
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(transition(current: true, distanceToBottom: 300, isInteracting: false))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 300))
        #expect(landing(geometry(offsetY: 0), userIsScrolledAway: true) == .finish(.yieldToUser))
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

    @Test func gestureObservedWhileForcedFollowPendingCancelsItImmediately() {
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(takesOver(isInteracting: true, isFollowing: true))
        #expect(!takesOver(isInteracting: false, isFollowing: true))
        #expect(!takesOver(isInteracting: true, isFollowing: false))
        #expect(!transition(current: false, distanceToBottom: 20, isInteracting: true))
        #expect(latch(distanceToBottom: 20, isInteracting: true))
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

    @Test func forcedFollowTakeoverLatchReleasesWhenTheGestureRestsPinned() {
        #expect(latch(distanceToBottom: 300, isInteracting: true))
        #expect(latch(distanceToBottom: 300, isInteracting: false))
        #expect(latch(distanceToBottom: 0, isInteracting: true))
        #expect(!latch(distanceToBottom: 0, isInteracting: false))
        #expect(!latch(distanceToBottom: 50, isInteracting: false))
        #expect(!latch(distanceToBottom: 300, isInteracting: true, current: false))
        #expect(honorForced(takenOver: false))
    }

    @Test func phaseOnlyInteractionYieldsForcedFollowAndLanding() {
        #expect(!executeFollow(forced: true, distanceToBottom: nil, isInteracting: true))
        #expect(landing(nil, isInteracting: true) == .finish(.yieldToUser))
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
    }

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
}
