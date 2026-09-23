import CoreGraphics

/// Bounded forced-follow landing and its demo report. The complementary blank-end
/// state machine is in ConversationTranscriptScrollPolicy+Recovery.swift (#350).
extension ConversationTranscriptScrollPolicy {
    // Outcome order follows the landing state machine rather than spelling.
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

    /// One poll of the landing loop: either a step the loop continues from
    /// or the terminal that ends it.
    enum FollowLandingStep: Equatable {
        case `continue`(FollowLandingContinuation)
        case finish(FollowLandingTerminal)
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
}
