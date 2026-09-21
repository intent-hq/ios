import CoreGraphics
import Foundation

// #350's recovery policy remains adjacent to the existing landing policy so
// the two bounded state machines can be reviewed together.
// swiftlint:disable file_length type_body_length

enum ConversationTranscriptScrollPolicy {
    enum InitialScrollStep: Equatable {
        case perform
        case skip
        case waitForScrollView
    }

    enum MessageCountChangeDecision: Equatable {
        case none
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
        hasInitiallyScrolled: Bool
    ) -> MessageCountChangeDecision {
        if newCount == 0 { return .rearmEntryScroll }
        if newCount < oldCount { return .rePinIfPastEnd }
        if oldCount == 0, !hasInitiallyScrolled { return .runEntryScroll }
        return .none
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
        /// Past the end but still dragging or decelerating; check again later.
        case deferred
        /// The viewport rests within the content.
        case none
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
        /// Following, but under the finger or decelerating; re-check on settle.
        case deferred
        /// Settled short of the bottom inside the at-bottom band while
        /// following: the ordinary automatic follow closes the gap.
        case follow
        /// The container is unchanged or the viewport is not following.
        case none
        /// Pin straight back to the bottom.
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

    /// The settle re-check after a container resize: of a re-pin deferred
    /// while interacting, and of the per-frame re-pins a resize animation
    /// issued (the keyboard). Still interacting, or with a follow in flight
    /// that another settle source (`bottomBandRePinDecision`, the past-end
    /// clamp) already issued — the re-pin would cancel it mid-animation and
    /// re-issue the same scroll — it is deferred again and reads the landed
    /// distance instead. Settled short of the bottom within the at-bottom
    /// band while still following, the viewport is followed to the bottom —
    /// a row shorter than the threshold leaves exactly that gap under the
    /// last message, with no Go to End and no further geometry edge to close
    /// it. Settled past the threshold while still following, it is pinned
    /// straight back: only a gesture may set `userIsScrolledAway`, so a
    /// following viewport resting away with no gesture is one the resize
    /// displaced — the keyboard shrinking the transcript while the lazy
    /// stack re-estimated its rows walked the offset to the very top (#276),
    /// and the per-frame re-pins had consumed the away edge the growth
    /// re-pin would otherwise act on. A fling that carried the user past the
    /// threshold set the flag as its phase ended and is left where it
    /// stopped; a rest past the end belongs to the #271 clamp; an unknown
    /// distance (no scroll view) proves nothing.
    static func deferredContainerRePinDecision(
        distanceToBottom: CGFloat?,
        isInteracting: Bool,
        isFollowing: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool,
        driftTolerance: CGFloat = Constants.Conversation.Transcript.streamingFollowDriftTolerance,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> ContainerRePinDecision {
        guard shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return .none }
        if isInteracting || isFollowing { return .deferred }
        guard let distanceToBottom else { return .none }
        if isScrolledAway(distanceToBottom: distanceToBottom, atBottomThreshold: atBottomThreshold) {
            return .rePin
        }
        return isDriftedWithinBottomBand(
            distanceToBottom: distanceToBottom,
            driftTolerance: driftTolerance,
            atBottomThreshold: atBottomThreshold
        ) ? .follow : .none
    }

    enum BottomBandRePinDecision: Equatable {
        /// Following, but under the finger, decelerating, or with a follow
        /// in flight; re-check on settle.
        case deferred
        /// Not following (scrolled away, or before the entry scroll), or the
        /// viewport rests within `driftTolerance` of the bottom, at a
        /// negative distance the past-end clamp owns (#271), or at an
        /// unknown distance.
        case none
        /// Following and settled, with no gesture, at rest more than
        /// `driftTolerance` short of the bottom — past `atBottomThreshold`
        /// included: the automatic follow re-validates that distance and,
        /// from past the band, its drain re-pins it as content growth.
        case rePin
    }

    /// A new conversation's transcript starts shorter than its container, at
    /// a negative distance, and its first reply grows it past one page. The
    /// bottom anchor takes the pin over mid-growth and the viewport comes to
    /// rest a line or two short of the end (#346): under `atBottomThreshold`,
    /// so Go to End stays hidden, and with no gesture, so the away edge never
    /// fires. Streaming deltas read the distance before their content is
    /// laid out and are rate-limited, and streaming ending issues no scroll,
    /// so nothing closes the gap. The growth does cross from a negative band
    /// into band 0, and that edge — read on a pinned, settled transcript —
    /// schedules a settle re-check (`bottomBandRePinDecision`). A follow in
    /// flight does not suppress it: the last rows may lay out during that
    /// follow's completion window and its drain re-pins only on an away
    /// edge, so the request is kept and the re-check defers until the
    /// follow lands. An away edge without a gesture is content growth past
    /// the band: `shouldRePinAfterContentGrowth` re-pins it at once, and the
    /// re-check validates that single scroll once the growth has settled
    /// (a reply ending with several suggested prompts swaps in more than
    /// `atBottomThreshold` at stream end). Under the finger the edge is a
    /// gesture, not growth; before the entry scroll the viewport is not
    /// following yet.
    static func shouldRecheckBottomBandAfterEdge(
        isInteracting: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool
    ) -> Bool {
        !isInteracting && shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    /// The settle re-check scheduled by `shouldRecheckBottomBandAfterEdge`,
    /// and when streaming ends. Interacting, or with a follow in flight that
    /// a re-pin would land under, it is deferred again. Settled, a viewport
    /// still following that rests short of the bottom — past
    /// `driftTolerance`, so layout rounding is left alone — is followed
    /// there through the ordinary automatic follow, which re-validates the
    /// geometry when it runs: within the at-bottom band it scrolls, and past
    /// `atBottomThreshold` its drain re-pins the distance as content growth
    /// (`shouldRePinAfterContentGrowth`) — with no gesture the flag cannot
    /// have been raised. Content still shorter than the container rests at
    /// a negative distance that the past-end clamp owns (#271); an unknown
    /// distance (no scroll view) proves nothing; scrolled away or before the
    /// entry scroll nothing is following.
    static func bottomBandRePinDecision(
        distanceToBottom: CGFloat?,
        isInteracting: Bool,
        isFollowing: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool,
        driftTolerance: CGFloat = Constants.Conversation.Transcript.streamingFollowDriftTolerance
    ) -> BottomBandRePinDecision {
        guard shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return .none }
        if isInteracting || isFollowing { return .deferred }
        guard let distanceToBottom, distanceToBottom > driftTolerance else { return .none }
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

    // Outcome order follows the landing state machine rather than spelling.
    // swiftlint:disable sorted_enum_cases
    /// An intermediate step of a forced follow's landing loop: the loop
    /// polls again after it.
    enum FollowLandingContinuation: Equatable {
        /// No scroll view yet, or the geometry moved since the last poll.
        case settling
        /// At rest short of the bottom, even inside the at-bottom band:
        /// issue the scroll again.
        case scrollAgain
        /// At rest past the end of the content: clamp the offset back.
        case clampPastEnd
    }

    /// How a forced follow's landing loop ends; the only outcomes the
    /// landing report (see `forcedFollowLandingSummary`) can carry.
    enum FollowLandingTerminal: Equatable {
        /// At rest within `landingTolerance` of the bottom.
        case landed
        /// The user took over the scroll view; the gesture rule owns the flag.
        case yieldToUser
        /// Timed out, or the bounded corrections are spent: leave the pin.
        case giveUp
    }
    // swiftlint:enable sorted_enum_cases

    /// One poll of the landing loop: either a step the loop continues from
    /// or the terminal that ends it.
    enum FollowLandingStep: Equatable {
        case `continue`(FollowLandingContinuation)
        case finish(FollowLandingTerminal)
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
        correctionsLeft: Int,
        timedOut: Bool,
        userIsScrolledAway: Bool = false,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold,
        landingTolerance: CGFloat = Constants.Conversation.Transcript.followLandingTolerance
    ) -> FollowLandingStep {
        if isInteracting || userIsScrolledAway { return .finish(.yieldToUser) }
        if timedOut { return .finish(.giveUp) }
        guard let geometry, geometry == previous else { return .continue(.settling) }
        let distance = geometry.distanceToBottom
        if isPastEnd(
            distanceToBottom: distance,
            contentHeight: geometry.contentHeight,
            containerHeight: geometry.containerHeight,
            verticalInsets: geometry.verticalInsets,
            atBottomThreshold: atBottomThreshold
        ) {
            return correctionsLeft > 0 ? .continue(.clampPastEnd) : .finish(.giveUp)
        }
        if isScrolledAway(distanceToBottom: distance, atBottomThreshold: landingTolerance) {
            return correctionsLeft > 0 ? .continue(.scrollAgain) : .finish(.giveUp)
        }
        return .finish(.landed)
    }

    // Outcome order follows the recovery state machine rather than spelling.
    // swiftlint:disable sorted_enum_cases
    /// An intermediate step of the unrealized-end recovery loop: the loop
    /// polls again after it.
    enum UnrealizedEndRecoveryContinuation: Equatable {
        /// No scroll view yet, a follow or gesture in flight, the geometry
        /// moved since the last poll, or a geometry another path corrects.
        case settling
        /// At rest short of the bottom inside the band, which alone explains
        /// the end row being off screen: follow to the end once.
        case followToEnd
        /// At rest at the bottom by geometry with no end row realized, or a
        /// follow that changed nothing: page the offset up to `pageOffsetY`
        /// so the lazy stack realizes rows again, then follow back to the end.
        case recover(pageOffsetY: CGFloat)
    }

    /// How the unrealized-end recovery ends, consumed by its lifecycle and
    /// report (see `unrealizedEndRecoveryReport`).
    enum UnrealizedEndRecoveryTerminal: Equatable {
        /// The end row is realized, the viewport is not following, or the
        /// content is shorter than the container.
        case notNeeded
        /// Timed out, or the bounded corrections are spent, with the end row
        /// still unrealized. The lifecycle surfaces Go to End or transfers
        /// the give-up to a follow that owns the viewport.
        case giveUp
        /// A gesture, a rest away or a follow requested meanwhile claimed
        /// the viewport while a correction had it paged up: it is theirs.
        case yieldToUser
    }
    // swiftlint:enable sorted_enum_cases

    /// One poll of the recovery loop: either a step the loop continues from
    /// or the terminal that ends it.
    enum UnrealizedEndRecoveryStep: Equatable {
        case `continue`(UnrealizedEndRecoveryContinuation)
        case finish(UnrealizedEndRecoveryTerminal)
    }

    // swiftlint:disable function_parameter_count function_default_parameter_at_end
    /// Every re-pin judges the viewport by geometry alone, and the geometry
    /// can read at the bottom over a blank viewport (#338): a footer row
    /// shrinking the container right after the entry follow landed, on a
    /// transcript whose last rows re-measure once realized, left the
    /// container re-pin's `scrollTo` with a lazy stack that realized no rows
    /// at all — the offset agreed with the stack's estimate of its own size,
    /// so neither the past-end clamp (#271) nor the growth re-pin had an
    /// edge to fire on, and the entry follow had already reported `landed`.
    /// The end row's realization is the missing signal: a following
    /// viewport at rest within the at-bottom band, with no gesture and no
    /// follow in flight, whose end row is not realized is blank. It is
    /// recovered the way a user does — paged up a viewport, so rows realize
    /// above, and followed back to the end — a bounded number of times.
    /// A first rest short of the bottom inside the band explains the end
    /// row on its own and is followed to the end as the deferred container
    /// re-pin does; the page up is for a rest the geometry calls the bottom,
    /// or one that follow left unchanged. Content shorter than the container
    /// realizes every row, so nothing is inferred from it; a rest past the
    /// end or beyond the band is waited out like a follow, since the clamp
    /// or the growth re-pin that owns it is on its way; and a user who
    /// scrolled away legitimately has the end row off screen.
    static func unrealizedEndRecoveryStep(
        geometry: ViewportGeometry?,
        previous: ViewportGeometry?,
        isEndRealized: Bool,
        isInteracting: Bool,
        isFollowing: Bool,
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool,
        correctionsLeft: Int,
        correctionsSpent: Int = 0,
        timedOut: Bool,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold,
        landingTolerance: CGFloat = Constants.Conversation.Transcript.followLandingTolerance
    ) -> UnrealizedEndRecoveryStep {
        if isEndRealized { return .finish(.notNeeded) }
        guard shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return .finish(.notNeeded) }
        if timedOut { return .finish(.giveUp) }
        if isInteracting || isFollowing { return .continue(.settling) }
        guard let geometry, geometry == previous else { return .continue(.settling) }
        guard geometry.contentHeight > geometry.containerHeight - geometry.verticalInsets else {
            return .finish(.notNeeded)
        }
        let distance = geometry.distanceToBottom
        if isPastEnd(
            distanceToBottom: distance,
            contentHeight: geometry.contentHeight,
            containerHeight: geometry.containerHeight,
            verticalInsets: geometry.verticalInsets,
            atBottomThreshold: atBottomThreshold
        ) || isScrolledAway(distanceToBottom: distance, atBottomThreshold: atBottomThreshold) {
            return .continue(.settling)
        }
        guard correctionsLeft > 0 else { return .finish(.giveUp) }
        if correctionsSpent == 0, isDriftedWithinBottomBand(
            distanceToBottom: distance,
            driftTolerance: landingTolerance,
            atBottomThreshold: atBottomThreshold
        ) {
            return .continue(.followToEnd)
        }
        return .continue(
            .recover(pageOffsetY: max(-geometry.topInset, geometry.contentOffsetY - geometry.containerHeight))
        )
    }
    // swiftlint:enable function_parameter_count function_default_parameter_at_end

    /// A correction that paged the viewport up follows back to the end only
    /// if nothing claimed the viewport while the rows realized: a gesture
    /// (the finger, or the deceleration after it), a rest the gesture left
    /// away, or a follow requested meanwhile (the user's message, Go to End,
    /// content) each own it from here and would be scrolled over by the
    /// follow back; the correction yields instead.
    static func unrealizedEndRecoveryMayFollowBack(
        isInteracting: Bool,
        userIsScrolledAway: Bool,
        isFollowing: Bool
    ) -> Bool {
        !isInteracting && !userIsScrolledAway && !isFollowing
    }

    /// The transcript's accessibility value under `--demo-data`: the last
    /// forced follow's outcome and the corrections it spent, e.g.
    /// `lastForcedFollow=landed corrections=1`, or
    /// `lastForcedFollow=pending` while one is in flight (or before the
    /// first). Lets the XCUITests assert the follow landed rather than gave
    /// up with the pin kept, which the visible geometry alone cannot tell
    /// apart within the at-bottom band (#304, #305). `endRecovery` (see
    /// `UnrealizedEndRecoveryReport.summary`) is appended once the follow
    /// has reported, never to the pending report the tests compare whole.
    static func forcedFollowLandingSummary(
        outcome: FollowLandingTerminal?,
        corrections: Int,
        endRecovery: String? = nil
    ) -> String {
        guard let outcome else { return "lastForcedFollow=pending" }
        let name: String
        switch outcome {
        case .landed: name = "landed"
        case .giveUp: name = "giveUp"
        case .yieldToUser: name = "yieldToUser"
        }
        let summary = "lastForcedFollow=\(name) corrections=\(corrections)"
        guard let endRecovery else { return summary }
        return "\(summary) \(endRecovery)"
    }

    /// How the last unrealized-end recovery episode resolved
    /// (`UnrealizedEndRecoveryReport.reason`).
    enum UnrealizedEndRecoveryReason: String, Equatable {
        /// The episode's task was cancelled (a takeover or the view
        /// disappearing) before it resolved.
        case cancelled
        /// The budget was spent or the timeout hit over an unrealized
        /// end row; Go to End is shown.
        case gaveUp
        /// The last episode resolved without spending a correction.
        case noCorrectionNeeded
        /// No episode was ever armed on this transcript.
        case notAttempted
        /// The last episode corrected the viewport at least once and the
        /// end row was realized when it resolved.
        case recovered
        /// An episode is armed and has not resolved.
        case recovering
        /// The last episode corrected the viewport and resolved as
        /// nothing left to do (not following, content short of the
        /// container) with the end row still unrealized: not recovered,
        /// and not a give-up either — the budget was not spent and Go
        /// to End is not shown.
        case unverified
        /// A gesture, a rest away or a follow claimed the viewport.
        case yieldedToUser
    }

    /// The unrealized-end recovery's demo-only report: how the last episode
    /// resolved, with the evidence the label rests on. Reported by
    /// `unrealizedEndRecoveryReport`, which alone decides the reason, so a
    /// reader cannot be told `recovered` by a resolution that never
    /// realized the end row.
    struct UnrealizedEndRecoveryReport: Equatable {
        let reason: UnrealizedEndRecoveryReason
        /// Corrections the last episode spent.
        let corrections: Int
        /// Episodes armed on this transcript so far.
        let episodes: Int
        /// Whether the end row was realized when the last episode resolved.
        let endRealized: Bool

        /// `endRecovery=<reason> corrections=N episodes=N endRealized=<true|false>`.
        var summary: String {
            "endRecovery=\(reason.rawValue) corrections=\(corrections) episodes=\(episodes) endRealized=\(endRealized)"
        }
    }

    /// Classifies the last recovery episode. `outcome` is the terminal the
    /// episode resolved on, nil while it is still running (or, with no
    /// episode armed, before the first); `cancelled` names an episode whose
    /// task was cancelled and overrides whatever terminal it reached. No
    /// episode is `notAttempted`. A cancelled, yielded or given-up episode
    /// is never `recovered`, nor is a `.notNeeded` resolution that spent no
    /// correction (`noCorrectionNeeded`) or left the end row unrealized
    /// (`unverified`): `recovered` needs a correction and the end row
    /// realized at the finish, both. An episode still on an intermediate
    /// step has no terminal yet, so it is `recovering`.
    static func unrealizedEndRecoveryReport(
        outcome: UnrealizedEndRecoveryTerminal?,
        corrections: Int,
        episodes: Int,
        endRealized: Bool,
        cancelled: Bool
    ) -> UnrealizedEndRecoveryReport {
        let reason = unrealizedEndRecoveryReason(
            outcome: outcome,
            corrections: corrections,
            episodes: episodes,
            endRealized: endRealized,
            cancelled: cancelled
        )
        return UnrealizedEndRecoveryReport(
            reason: reason,
            corrections: corrections,
            episodes: episodes,
            endRealized: endRealized
        )
    }

    private static func unrealizedEndRecoveryReason(
        outcome: UnrealizedEndRecoveryTerminal?,
        corrections: Int,
        episodes: Int,
        endRealized: Bool,
        cancelled: Bool
    ) -> UnrealizedEndRecoveryReason {
        guard episodes > 0 else { return .notAttempted }
        if cancelled { return .cancelled }
        guard let outcome else { return .recovering }
        switch outcome {
        case .giveUp:
            return .gaveUp
        case .yieldToUser:
            return .yieldedToUser
        case .notNeeded:
            guard corrections > 0 else { return .noCorrectionNeeded }
            return endRealized ? .recovered : .unverified
        }
    }
}
// swiftlint:enable file_length type_body_length
