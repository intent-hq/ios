import CoreGraphics
import Foundation

/// Entry, follow requests, and user takeover decisions. Geometry/re-pinning,
/// landing, and unrealized-end recovery live in responsibility-named extensions.
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

    /// A wholesale transcript update needs different handling from an append.
    /// Empty content clears the viewport state and re-arms entry scrolling; the
    /// next non-empty snapshot runs that entry scroll. A shorter replacement can
    /// leave UIKit's offset past its new end, so it enters the existing #350
    /// resting past-end recovery path.
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

    /// Appends (including an append arriving with history) still follow the
    /// live tail. A pure prepend must never treat the existing last user row
    /// as a new send or re-arm entry scrolling.
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

    /// Sequencing of the entry scroll against the finder. A `scrollTo` issued
    /// before the transcript's UIScrollView is hosted is lost, so the scroll
    /// waits for the finder to resolve; once the bounded wait elapses it runs
    /// regardless, so a finder that never resolves cannot leave the transcript
    /// unscrolled. It performs at most once, whichever path gets there first.
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

    /// The scrolled-away flag driving "Go to End" and follow-to-bottom, on a
    /// geometry edge. Once pinned, the transcript stays pinned until the user
    /// drags it up (#281): the only transition to "scrolled away" is a
    /// gesture — the finger on the scroll view or the deceleration after it —
    /// that leaves the viewport past `atBottomThreshold`. Content growth of
    /// any kind (a row re-measuring, a footer row, the keyboard, streaming,
    /// an append) reads the same "away" geometry without a gesture and keeps
    /// the current flag; #272, #280 and #281 each patched one such instance.
    /// Geometry reading within the threshold re-pins, gesture or not (the
    /// user dragged back, or Go to End landed) — provided the end row is
    /// realized: a viewport resting over an unrealized end row reads "at
    /// bottom" geometrically while showing nothing (#338), so that edge
    /// keeps the current flag until the row realizes and the ordinary rule
    /// applies.
    static func scrolledAwayTransition(
        current: Bool,
        geometryAway: Bool,
        isInteracting: Bool,
        isEndRealized: Bool
    ) -> Bool {
        guard geometryAway else { return isEndRealized ? false : current }
        return isInteracting ? true : current
    }

    /// A geometry edge reading "away" without a gesture on a pinned, settled
    /// transcript is content that grew under the viewport, and the pin is
    /// followed to the new end. A follow already in flight lands there on
    /// its own; under the finger the edge is a gesture, not growth; before
    /// the entry scroll has decided the viewport is not following yet.
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

    /// Discrete, user-visible transitions (a message appended, "Go to End",
    /// chrome growing under the transcript) scroll whenever the transcript is
    /// following the bottom.
    static func shouldFollowToBottom(
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool
    ) -> Bool {
        hasInitiallyScrolled && !userIsScrolledAway
    }

    /// The thinking indicator is appended when streaming starts, so that edge
    /// scrolls like any other append; streaming ending only removes it and the
    /// bottom-anchored viewport needs no scroll.
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

    /// `userIsScrolledAway` clearing is a follow only when Go to End cleared
    /// it: the button sits outside the `ScrollViewReader`, so it records the
    /// request and clears the flag for the `onChange` to scroll. A geometry
    /// edge clearing the flag means the viewport already rests within
    /// `atBottomThreshold` and nothing is to be scrolled. Such an edge can
    /// also be a transient mid-drag reading (a lazily realized row
    /// re-measuring), and a forced scroll then fights the user's pan: the
    /// interrupted animation left the geometry observer silent, so the next
    /// swipes reached far up the transcript without Go to End (#280). The
    /// request is its own flag, not the follow-in-flight state, so an edge
    /// clearing the flag while another forced follow is in flight does not
    /// queue a second one.
    static func shouldFollowOnScrolledAwayCleared(goToEndRequested: Bool) -> Bool {
        goToEndRequested
    }

    /// Streaming deltas grow content that `.defaultScrollAnchor(.bottom)`
    /// already keeps pinned, so a viewport at the bottom is never scrolled for
    /// them. A delta only re-pins a viewport that drifted past
    /// `driftTolerance` while still inside the at-bottom band (the user has
    /// not scrolled away), and at most once per `minimumInterval`.
    /// `distanceToBottom` is nil until the scroll view has been found; nothing
    /// scrolls then.
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

    /// Re-validated when a debounced follow finally runs. Forced follows (Go to
    /// End, a new user message, the entry scroll, the thinking indicator
    /// appearing) are all requested from a pinned viewport, so at execution a
    /// raised `userIsScrolledAway` can only be a gesture that came after the
    /// request — it wins whether it is still in progress (`isInteracting`) or
    /// already ended away during the debounce, and the forced follow yields
    /// without re-queuing itself; the geometry edges of the gesture carry the
    /// scrolled-away rule from there. An automatic
    /// follow is dropped when the user scrolled away during the debounce — by
    /// the flag or by the live distance having left the at-bottom band — or
    /// when the viewport is already pinned; an unknown distance (scroll view
    /// not found yet) proves neither, so the follow still runs. A dropped
    /// automatic follow is reconciled by its caller against the live geometry
    /// (see `shouldRePinAfterContentGrowth`): a distance past the band with no
    /// gesture is content that grew during the debounce, not the user.
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

    /// A user gesture observed while a follow is pending — SwiftUI reporting
    /// a user-driven scroll phase, or a geometry edge under UIKit tracking,
    /// dragging or deceleration — takes the follow over there and then: the
    /// pending task (debounce or landing loop) is cancelled at the moment the
    /// gesture is seen, not re-checked when it comes due. The gesture's final
    /// geometry edge can be dropped (#280) and its ending delivered before
    /// that check, which would then read idle and pinned and scroll the user
    /// back from where the gesture left the viewport.
    static func gestureTakesOverPendingFollow(isInteracting: Bool, isFollowing: Bool) -> Bool {
        isInteracting && isFollowing
    }

    /// The takeover of a forced follow is latched for the rest of the gesture
    /// and for as long as it left the viewport away, so a forced follow raised
    /// by content meanwhile (the thinking indicator appearing) does not revive
    /// the scroll the gesture cancelled (see `shouldHonorForcedFollow`). The
    /// latch releases once the viewport rests within `atBottomThreshold` with
    /// no gesture in progress — the gesture ended pinned or dragged back — and
    /// is cleared outright by an explicit request: Go to End, or the user's
    /// own message.
    static func forcedFollowTakeoverLatch(current: Bool, geometryAway: Bool, isInteracting: Bool) -> Bool {
        current && (geometryAway || isInteracting)
    }

    /// Forced follows are honored unless a gesture's takeover is latched; the
    /// explicit requests clear the latch before asking, so only content-raised
    /// forced follows are refused.
    static func shouldHonorForcedFollow(takenOverByGesture: Bool) -> Bool {
        !takenOverByGesture
    }

    // Outcome order follows the follow state machine rather than spelling.
    // swiftlint:disable sorted_enum_cases
    /// Every way a follow ends once requested, consumed by the recovery
    /// lifecycle when a give-up was transferred to that follow.
    enum FollowTerminal: Equatable {
        /// The follow scrolled; a forced one carries its landing terminal,
        /// an automatic one (which only waits out its animation) carries nil.
        case executed(FollowLandingTerminal?)
        /// An automatic follow whose re-validation at the due time failed
        /// (see `shouldExecuteFollow`).
        case dropped
        /// A forced follow that came due under a gesture, or scrolled away.
        case yielded
        /// A gesture took the pending follow over.
        case cancelled
        /// A newer request superseded the follow before it came due.
        case replaced
    }
    // swiftlint:enable sorted_enum_cases
}
