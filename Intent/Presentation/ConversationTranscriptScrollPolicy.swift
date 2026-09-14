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
        /// Past the end with no position to return to; only Go to End can help.
        case unrecoverable
    }

    /// Whether, and where, a resting viewport must be re-pinned to the bottom
    /// (#271). Two readings of "past the end":
    ///
    /// - By the scroll view's own content size (`isPastEnd`): the offset is
    ///   stale for content that shrank; the viewport is clamped by the distance.
    /// - By the end row not being realized while the geometry reads "at
    ///   bottom": at the real bottom the end row is always on screen, so the
    ///   two together mean the lazy stack has stretched its height to cover a
    ///   viewport that overshot the rows (it never shrinks below the visible
    ///   region) and no geometry read exposes the blank band. The last end
    ///   measured while the row was realized is the only known good position;
    ///   the viewport is only ever moved up, so a stale end can never push it
    ///   past newer content.
    ///
    /// A bounce past the bottom reads the same geometry, so a viewport the
    /// user is still dragging, or that is decelerating (which includes the
    /// bounce back), is left to settle on its own.
    static func rePinDecision(
        contentOffsetY: CGFloat,
        distanceToBottom: CGFloat,
        isInteracting: Bool,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        isEndRowRealized: Bool = true,
        lastKnownContentEnd: CGFloat? = nil,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> RePinDecision {
        let targetY: CGFloat
        if isPastEnd(
            distanceToBottom: distanceToBottom,
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            verticalInsets: topInset + bottomInset,
            atBottomThreshold: atBottomThreshold
        ) {
            targetY = contentOffsetY + distanceToBottom
        } else if !isEndRowRealized,
                  !isScrolledAway(distanceToBottom: distanceToBottom, atBottomThreshold: atBottomThreshold) {
            guard let lastKnownContentEnd else { return .unrecoverable }
            let knownEndOffsetY = max(lastKnownContentEnd + bottomInset - containerHeight, -topInset)
            guard knownEndOffsetY < contentOffsetY else { return .none }
            targetY = knownEndOffsetY
        } else {
            return .none
        }
        return isInteracting ? .deferred : .rePin(offsetY: targetY)
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
}