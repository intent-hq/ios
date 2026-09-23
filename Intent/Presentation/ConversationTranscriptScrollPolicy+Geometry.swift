import CoreGraphics

/// Live geometry and the re-pin decisions for past-end, container, and bottom-band drift.
extension ConversationTranscriptScrollPolicy {
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
}
