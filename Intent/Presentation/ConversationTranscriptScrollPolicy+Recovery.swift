import CoreGraphics

/// Bounded unrealized-end recovery and its demo report. Geometry-confirmed
/// follow landing is in ConversationTranscriptScrollPolicy+Landing.swift (#350).
extension ConversationTranscriptScrollPolicy {
    // Outcome order follows the recovery state machine rather than spelling.
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
