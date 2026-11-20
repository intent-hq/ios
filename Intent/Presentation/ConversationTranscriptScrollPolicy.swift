import CoreGraphics
import Foundation

enum ConversationTranscriptScrollPolicy {
    enum InitialScrollStep: Equatable {
        case perform
        case preserveViewport
        case skip
        case waitForScrollView
    }

    enum MessageCountChangeDecision: Equatable {
        case none
        case preserveViewport
        case rearmEntryScroll
        case rePinIfPastEnd
        case runEntryScroll
    }

    static func messageCountChangeDecision(
        from oldCount: Int,
        to newCount: Int,
        hasInitiallyScrolled: Bool,
        isPrepend: Bool = false
    ) -> MessageCountChangeDecision {
        if isPrepend { return .preserveViewport }
        if newCount == 0 { return .rearmEntryScroll }
        if newCount < oldCount { return .rePinIfPastEnd }
        if oldCount == 0, !hasInitiallyScrolled { return .runEntryScroll }
        return .none
    }

    static func isHistoryPrepend(from oldIDs: [String], to newIDs: [String]) -> Bool {
        !oldIDs.isEmpty && newIDs.count > oldIDs.count && newIDs.suffix(oldIDs.count).elementsEqual(oldIDs)
    }

    private static let historyPrefetchScreenCount: CGFloat = 3

    static func isNearHistoryTop(contentOffsetY: CGFloat, topInset: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard contentOffsetY.isFinite, topInset.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return false }
        return contentOffsetY + topInset <= viewportHeight * historyPrefetchScreenCount
    }

    static func shouldLoadOlderMessages(
        isNearTop: Bool,
        hasInitiallyScrolled: Bool,
        hasUserScrolled: Bool,
        isFollowing: Bool,
        canRequestPage: Bool
    ) -> Bool {
        isNearTop && hasInitiallyScrolled && hasUserScrolled && !isFollowing && canRequestPage
    }

    static func initialScrollStep(
        alreadyPerformed: Bool,
        scrollViewResolved: Bool,
        scrollViewWaitElapsed: Bool,
        entryMetadataReady: Bool = true
    ) -> InitialScrollStep {
        if alreadyPerformed { return .skip }
        if scrollViewResolved || scrollViewWaitElapsed { return entryMetadataReady ? .perform : .preserveViewport }
        return .waitForScrollView
    }

    static func scrolledAwayTransition(
        current: Bool,
        geometryAway: Bool,
        isInteracting: Bool,
        isEndRealized: Bool
    ) -> Bool {
        guard geometryAway else { return isEndRealized ? false : current }
        return isInteracting ? true : current
    }

    static func shouldRePinAfterContentGrowth(
        geometryAway: Bool,
        isInteracting: Bool,
        isFollowing: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool
    ) -> Bool {
        geometryAway && !isInteracting && !isFollowing && shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    static func shouldFollowToBottom(
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool
    ) -> Bool {
        hasInitiallyScrolled && !userIsScrolledAway
    }

    static func shouldFollowOnStreamingStateChange(
        isStreaming: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool
    ) -> Bool {
        isStreaming && shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    static func shouldFollowOnScrolledAwayCleared(goToEndRequested: Bool) -> Bool {
        goToEndRequested
    }

    static func shouldAnimateGoToEnd(geometry: ViewportGeometry?) -> Bool {
        guard let geometry else { return true }
        let visibleHeight = geometry.containerHeight - geometry.verticalInsets
        let distance = geometry.distanceToBottom
        guard visibleHeight.isFinite, visibleHeight > 0, distance.isFinite else { return true }
        return distance <= visibleHeight
    }

    enum GoToEndVisibilityTransition: Equatable {
        case fade
        case slideAndFade
    }

    static func goToEndVisibilityTransition(reduceMotion: Bool) -> GoToEndVisibilityTransition {
        reduceMotion ? .fade : .slideAndFade
    }

    static func animatesFollow(requested: Bool, reduceMotion: Bool) -> Bool {
        requested && !reduceMotion
    }

    static func shouldFollowStreamingDelta(
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool,
        distanceToBottom: CGFloat?,
        now: TimeInterval,
        lastFollowAt: TimeInterval?,
        driftTolerance: CGFloat = Constants.Conversation.Transcript.streamingFollowDriftTolerance,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold,
        minimumInterval: TimeInterval = Constants.Conversation.Transcript.streamingFollowMinimumInterval
    ) -> Bool {
        guard shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return false }
        guard let distanceToBottom, isDriftedWithinBottomBand(
            distanceToBottom: distanceToBottom,
            driftTolerance: driftTolerance,
            atBottomThreshold: atBottomThreshold
        ) else { return false }
        guard let lastFollowAt else { return true }
        return now - lastFollowAt >= minimumInterval
    }

    static func shouldExecuteFollow(
        forced: Bool,
        userIsScrolledAway: Bool,
        distanceToBottom: CGFloat?,
        isInteracting: Bool = false,
        driftTolerance: CGFloat = Constants.Conversation.Transcript.streamingFollowDriftTolerance,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Bool {
        if userIsScrolledAway { return false }
        if forced { return !isInteracting }
        guard let distanceToBottom else { return true }
        return isDriftedWithinBottomBand(
            distanceToBottom: distanceToBottom,
            driftTolerance: driftTolerance,
            atBottomThreshold: atBottomThreshold
        )
    }

    static func gestureTakesOverPendingFollow(isInteracting: Bool, isFollowing: Bool) -> Bool {
        isInteracting && isFollowing
    }

    static func forcedFollowTakeoverLatch(current: Bool, geometryAway: Bool, isInteracting: Bool) -> Bool {
        current && (geometryAway || isInteracting)
    }

    static func shouldHonorForcedFollow(takenOverByGesture: Bool) -> Bool {
        !takenOverByGesture
    }

    // Outcome order follows the follow state machine rather than spelling.
    // swiftlint:disable sorted_enum_cases
    enum FollowTerminal: Equatable {
        case executed(FollowLandingTerminal?)
        case dropped
        case yielded
        case cancelled
        case replaced
    }
    // swiftlint:enable sorted_enum_cases
}
