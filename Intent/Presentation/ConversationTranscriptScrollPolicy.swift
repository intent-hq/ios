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

    /// The scrolled-away flag driving "Go to End" and follow-to-bottom, on a
    /// geometry edge. Once pinned, the transcript stays pinned until the user
    /// drags it up (#281): the only transition to "scrolled away" is a
    /// gesture — the finger on the scroll view or the deceleration after it —
    /// that leaves the viewport past `atBottomThreshold`. Content growth of
    /// any kind (a row re-measuring, a footer row, the keyboard, streaming,
    /// an append) reads the same "away" geometry without a gesture and keeps
    /// the current flag; #272, #280 and #281 each patched one such instance.
    /// Geometry reading within the threshold always re-pins, gesture or not
    /// (the user dragged back, or Go to End landed).
    static func scrolledAwayTransition(
        current: Bool,
        geometryAway: Bool,
        isInteracting: Bool
    ) -> Bool {
        guard geometryAway else { return false }
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

    /// Everything a landing or re-pin decision reads from the live scroll
    /// view. `containerHeight` is the full bounds; the adjusted insets are
    /// part of it because the keyboard or safe area can change them between
    /// two reads while offset, content size and bounds stay the same.
    struct ViewportGeometry: Equatable {
        let contentOffsetY: CGFloat
        let contentHeight: CGFloat
        let containerHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat

        var distanceToBottom: CGFloat {
            ConversationTranscriptScrollPolicy.distanceToBottom(
                contentHeight: contentHeight,
                contentOffsetY: contentOffsetY,
                containerHeight: containerHeight,
                bottomInset: bottomInset
            )
        }

        var verticalInsets: CGFloat { topInset + bottomInset }
    }

    enum FollowLandingStep: Equatable {
        /// No scroll view yet, or the geometry moved since the last poll.
        case settling
        /// At rest within `landingTolerance` of the bottom.
        case landed
        /// At rest short of the bottom, even inside the at-bottom band:
        /// issue the scroll again.
        case scrollAgain
        /// At rest past the end of the content: clamp the offset back.
        case clampPastEnd
        /// The user took over the scroll view; the gesture rule owns the flag.
        case yieldToUser
        /// Timed out, or the bounded corrections are spent: leave the pin.
        case giveUp
    }

    /// A forced follow (entry, a new user message, the thinking indicator,
    /// Go to End) is complete only when the live geometry confirms it (#281).
    /// `scrollTo` targets the bottom as laid out when it is issued, and rows
    /// the lazy stack realizes afterwards re-measure: taller, the viewport
    /// rests short of the bottom (Go to End on the demo transcript landed
    /// 379 points short); shorter, it rests past the end over a blank band
    /// (#271). Ending the follow on a timer then copied that geometry into
    /// the flag, Go to End showed, and every later append was skipped as
    /// "user scrolled away". The landing is polled instead: two identical
    /// reads mean the geometry is at rest, and a rest short of the bottom is
    /// scrolled again, past the end clamped, each a bounded number of times;
    /// a bound that runs out leaves the pin as it is, so no follow ever
    /// shows Go to End without a gesture. Content shorter than the container
    /// rests at a negative distance and is landed. The user takes over by a
    /// gesture in progress or by one that already set `userIsScrolledAway`
    /// between two polls: a forced follow starts pinned, so the flag being
    /// raised while it lands is the user's later intent.
    ///
    /// Short of the bottom is judged against `landingTolerance`, not the
    /// at-bottom band: the last rows the lazy stack realized grew the content
    /// by less than `atBottomThreshold`, so the viewport rested a few dozen
    /// points short reading "at bottom" — Go to End hidden — with the rows
    /// under the last message (suggested prompts on entry, the thinking
    /// indicator after a send) still below the viewport (#304, #305). Past
    /// the end keeps the band: a rest that far past it is a blank band, and
    /// the bounce back reads the same geometry.
    static func followLandingStep(
        geometry: ViewportGeometry?,
        previous: ViewportGeometry?,
        isInteracting: Bool,
        userIsScrolledAway: Bool = false,
        correctionsLeft: Int,
        timedOut: Bool,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold,
        landingTolerance: CGFloat = Constants.Conversation.Transcript.followLandingTolerance
    ) -> FollowLandingStep {
        if isInteracting || userIsScrolledAway { return .yieldToUser }
        if timedOut { return .giveUp }
        guard let geometry, geometry == previous else { return .settling }
        let distance = geometry.distanceToBottom
        if isPastEnd(
            distanceToBottom: distance,
            contentHeight: geometry.contentHeight,
            containerHeight: geometry.containerHeight,
            verticalInsets: geometry.verticalInsets,
            atBottomThreshold: atBottomThreshold
        ) {
            return correctionsLeft > 0 ? .clampPastEnd : .giveUp
        }
        if isScrolledAway(distanceToBottom: distance, atBottomThreshold: landingTolerance) {
            return correctionsLeft > 0 ? .scrollAgain : .giveUp
        }
        return .landed
    }

    /// The transcript's accessibility value under `--demo-data`: the last
    /// forced follow's outcome and the corrections it spent, e.g.
    /// `lastForcedFollow=landed corrections=1`, or
    /// `lastForcedFollow=pending` while one is in flight (or before the
    /// first). Lets the XCUITests assert the follow landed rather than gave
    /// up with the pin kept, which the visible geometry alone cannot tell
    /// apart within the at-bottom band (#304, #305).
    static func forcedFollowLandingSummary(outcome: FollowLandingStep?, corrections: Int) -> String {
        guard let outcome else { return "lastForcedFollow=pending" }
        let name: String
        switch outcome {
        case .landed: name = "landed"
        case .giveUp: name = "giveUp"
        case .yieldToUser: name = "yieldToUser"
        case .settling: name = "settling"
        case .scrollAgain: name = "scrollAgain"
        case .clampPastEnd: name = "clampPastEnd"
        }
        return "lastForcedFollow=\(name) corrections=\(corrections)"
    }
}