import CoreGraphics
import Foundation

enum ConversationTranscriptScrollPolicy {
    enum InitialScrollStep: Equatable {
        case perform
        case waitForScrollView
        case skip
    }

    /// Sequencing of the entry scroll against the finder. A `scrollTo` issued
    /// before the transcript's UIScrollView is hosted is lost, so the scroll
    /// waits for the finder to resolve; once the bounded wait elapses it runs
    /// regardless, so a finder that never resolves cannot leave the transcript
    /// unscrolled. It performs at most once, whichever path gets there first.
    static func initialScrollStep(
        alreadyPerformed: Bool,
        scrollViewResolved: Bool,
        scrollViewWaitElapsed: Bool
    ) -> InitialScrollStep {
        if alreadyPerformed { return .skip }
        if scrollViewResolved || scrollViewWaitElapsed { return .perform }
        return .waitForScrollView
    }

    /// Points between the viewport's bottom edge and the end of the content:
    /// 0 at rest at the bottom, negative while bouncing past it or when the
    /// content is shorter than the container.
    static func distanceToBottom(
        contentHeight: CGFloat,
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        contentHeight + bottomInset - contentOffsetY - containerHeight
    }

    static func isScrolledAway(
        distanceToBottom: CGFloat,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Bool {
        distanceToBottom > atBottomThreshold
    }

    /// `onScrollGeometryChange` compares successive transformed values and
    /// runs its action on a change, but a value flipping twice inside one
    /// layout pass (a lazily realized row re-measuring mid-drag read 52, 46,
    /// then 172 points from the bottom within 8 ms) had only the first flip
    /// delivered while the observer recorded the second, so the scrolled-away
    /// flag stayed frozen for the rest of that scroll (#280). Observing the
    /// distance in bands of `atBottomThreshold` next to the flag makes the
    /// next band crossing deliver the current flag again, bounding the loss
    /// to one band of travel.
    static func distanceBand(
        distanceToBottom: CGFloat,
        bandHeight: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Int {
        Int((distanceToBottom / bandHeight).rounded(.down))
    }

    /// The viewport sits past the end of content that is taller than its
    /// container: the last rows are hidden above a blank band, yet
    /// `isScrolledAway` reads "at bottom". Content shorter than the container
    /// rests at a negative distance by construction and is never past the end.
    /// `verticalInsets` is the container's top + bottom content inset, which
    /// `containerHeight` (the full bounds) includes but the content does not.
    static func isPastEnd(
        distanceToBottom: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        verticalInsets: CGFloat = 0,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Bool {
        contentHeight > containerHeight - verticalInsets
            && distanceToBottom < -atBottomThreshold
    }

    enum RePinDecision: Equatable {
        /// The viewport rests within the content.
        case none
        /// Past the end but still dragging or decelerating; check again later.
        case deferred
        case rePin(offsetY: CGFloat)
    }

    /// Whether, and where, a resting viewport must be re-pinned to the bottom
    /// (#271): past the end (`isPastEnd`) the offset is stale for content that
    /// shrank, and the distance is exactly the correction. A bounce past the
    /// bottom reads the same geometry, so a viewport the user is still
    /// dragging, or that is decelerating (which includes the bounce back), is
    /// left to settle on its own.
    static func rePinDecision(
        contentOffsetY: CGFloat,
        distanceToBottom: CGFloat,
        isInteracting: Bool,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        verticalInsets: CGFloat = 0,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> RePinDecision {
        guard isPastEnd(
            distanceToBottom: distanceToBottom,
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            verticalInsets: verticalInsets,
            atBottomThreshold: atBottomThreshold
        ) else { return .none }
        return isInteracting ? .deferred : .rePin(offsetY: contentOffsetY + distanceToBottom)
    }

    enum ContainerRePinDecision: Equatable {
        /// The container is unchanged or the viewport is not following.
        case none
        /// Following, but under the finger or decelerating; re-check on settle.
        case deferred
        case rePin
    }

    /// A footer row appearing or disappearing under the transcript resizes
    /// its container while `contentOffset` stays where it was (#272). At rest
    /// at the bottom that slides the last rows under the new row and the
    /// geometry reads scrolled away, so a following viewport is re-pinned to
    /// the bottom. Scrolled away, the container resizes at its bottom edge and
    /// the content under the reader does not move, so nothing is adjusted;
    /// before the entry scroll the viewport is not following yet. A viewport
    /// under the user's finger, or still decelerating from a fling released
    /// just before the row lands (the bounce back at the bottom included), is
    /// not pinned right away — the re-pin would fight the pan or snap the
    /// fling back — but deferred to `deferredContainerRePinDecision` once the
    /// gesture has settled, as the #271 past-end clamp does; the edge the
    /// resize carries is applied meanwhile, so a row taller than the
    /// threshold shows Go to End as usual.
    static func containerHeightChangeDecision(
        oldContainerHeight: CGFloat,
        newContainerHeight: CGFloat,
        isInteracting: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool
    ) -> ContainerRePinDecision {
        guard oldContainerHeight != newContainerHeight, shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return .none }
        return isInteracting ? .deferred : .rePin
    }

    /// The settle re-check of a container re-pin deferred while interacting.
    /// Still interacting, it is deferred again. Settled, the viewport is
    /// followed to the bottom when it is still following and rests short of
    /// the bottom within the at-bottom band — a row shorter than the threshold
    /// leaves exactly that gap under the last message, with no Go to End and
    /// no further geometry edge to close it. A fling that carried the user
    /// past the threshold applied its edge on the way and is left where it
    /// stopped; an unknown distance (no scroll view) proves nothing.
    static func deferredContainerRePinDecision(
        distanceToBottom: CGFloat?,
        isInteracting: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool,
        driftTolerance: CGFloat = Constants.Conversation.Transcript.streamingFollowDriftTolerance,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> ContainerRePinDecision {
        guard shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return .none }
        if isInteracting { return .deferred }
        guard let distanceToBottom, isDriftedWithinBottomBand(
            distanceToBottom: distanceToBottom,
            driftTolerance: driftTolerance,
            atBottomThreshold: atBottomThreshold
        ) else { return .none }
        return .rePin
    }

    /// The scrolled-away flag driving "Go to End" and follow-to-bottom.
    /// `onScrollGeometryChange` is edge-triggered and its edges are ignored
    /// while the entry scroll or a programmatic follow is in flight; an edge
    /// that lands while gated would otherwise be lost for good, because the
    /// geometry emits no new edge until the threshold is crossed again. The
    /// live value is therefore kept and re-applied whenever the gate opens.
    /// A nil `live` means no edge has been observed yet, so `current` stands
    /// (e.g. the divider probe's flag before the entry scroll's edge lands).
    static func resolvedScrolledAway(
        live: Bool?,
        current: Bool,
        hasInitiallyScrolled: Bool,
        isScrollingToBottom: Bool
    ) -> Bool {
        guard let live, hasInitiallyScrolled, !isScrollingToBottom else { return current }
        return live
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
    /// it: the button sits outside the `ScrollViewReader`, so it raises
    /// `isScrollingToBottom` and clears the flag for the `onChange` to scroll.
    /// A geometry edge clearing the flag means the viewport already rests
    /// within `atBottomThreshold` and nothing is to be scrolled. Such an edge
    /// can also be a transient mid-drag reading (a lazily realized row
    /// re-measuring), and a forced scroll then fights the user's pan: the
    /// interrupted animation left the geometry observer silent, so the next
    /// swipes reached far up the transcript without Go to End (#280).
    static func shouldFollowOnScrolledAwayCleared(isScrollingToBottom: Bool) -> Bool {
        isScrollingToBottom
    }

    /// The band an automatic follow may re-pin from: drifted past
    /// `driftTolerance` but not past `atBottomThreshold`. `userIsScrolledAway`
    /// lags the geometry (and is frozen during a programmatic scroll), so the
    /// live distance is checked against the same threshold rather than
    /// trusting the flag alone.
    static func isDriftedWithinBottomBand(
        distanceToBottom: CGFloat,
        driftTolerance: CGFloat = Constants.Conversation.Transcript.streamingFollowDriftTolerance,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Bool {
        distanceToBottom > driftTolerance && !isScrolledAway(
            distanceToBottom: distanceToBottom,
            atBottomThreshold: atBottomThreshold
        )
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
    /// appearing) always land. An automatic follow is dropped when the user
    /// scrolled away during the debounce — by the flag or by the live distance
    /// having left the at-bottom band — or when the viewport is already pinned;
    /// an unknown distance (scroll view not found yet) proves neither, so the
    /// follow still runs.
    static func shouldExecuteFollow(
        forced: Bool,
        userIsScrolledAway: Bool,
        distanceToBottom: CGFloat?,
        driftTolerance: CGFloat = Constants.Conversation.Transcript.streamingFollowDriftTolerance,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Bool {
        if forced { return true }
        if userIsScrolledAway { return false }
        guard let distanceToBottom else { return true }
        return isDriftedWithinBottomBand(
            distanceToBottom: distanceToBottom,
            driftTolerance: driftTolerance,
            atBottomThreshold: atBottomThreshold
        )
    }

    /// `scrollTo` targets the bottom as laid out when the animation starts, and
    /// rows the lazy stack realizes during it grow the content underneath, so
    /// a forced follow can come to rest above the real bottom (Go to End on
    /// the 32-row demo transcript landed 379 points short). The follow used to
    /// be re-issued by the geometry edge clearing the flag, which #280 stopped
    /// so it would not fight the user's pan; the follow itself now re-scrolls
    /// while its landing still reads scrolled away, a bounded number of times.
    /// Automatic follows are not retried (the bottom anchor keeps a pinned
    /// viewport pinned and the next delta re-pins a drifted one), nor is any
    /// follow once the user has taken over the scroll view, and an unknown
    /// distance proves nothing.
    static func shouldRetryFollowLanding(
        forced: Bool,
        distanceToBottom: CGFloat?,
        isInteracting: Bool,
        retriesLeft: Int,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Bool {
        guard forced, retriesLeft > 0, !isInteracting, let distanceToBottom else { return false }
        return isScrolledAway(distanceToBottom: distanceToBottom, atBottomThreshold: atBottomThreshold)
    }
}