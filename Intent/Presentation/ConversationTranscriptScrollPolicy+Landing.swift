import CoreGraphics

extension ConversationTranscriptScrollPolicy {
    enum FollowLandingContinuation: Equatable {
        case settling
        case scrollAgain
        case clampPastEnd
    }

    enum FollowLandingTerminal: Equatable {
        case landed
        case yieldToUser
        case giveUp
    }

    enum FollowLandingStep: Equatable {
        case `continue`(FollowLandingContinuation)
        case finish(FollowLandingTerminal)
    }

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
