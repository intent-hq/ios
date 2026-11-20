import CoreGraphics

extension ConversationTranscriptScrollPolicy {
    enum UnrealizedEndRecoveryContinuation: Equatable {
        case settling
        case followToEnd
        case recover(pageOffsetY: CGFloat)
    }

    enum UnrealizedEndRecoveryTerminal: Equatable {
        case notNeeded
        case giveUp
        case yieldToUser
    }

    enum UnrealizedEndRecoveryStep: Equatable {
        case `continue`(UnrealizedEndRecoveryContinuation)
        case finish(UnrealizedEndRecoveryTerminal)
    }

    // Keep recovery inputs explicit and the optional correction history beside the required correction budget.
    // swiftlint:disable function_parameter_count function_default_parameter_at_end
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
        previousPageOffsetY: CGFloat? = nil,
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
        ), correctionsSpent == 0 {
            return .continue(.settling)
        }
        guard correctionsLeft > 0 else { return .finish(.giveUp) }
        if correctionsSpent == 0, distance > landingTolerance {
            return .continue(.followToEnd)
        }
        let top = -geometry.topInset
        let estimatedEnd = geometry.contentOffsetY + distance
        let searchFrom = min(geometry.contentOffsetY, previousPageOffsetY ?? geometry.contentOffsetY, estimatedEnd)
        let pageOffsetY = correctionsLeft == 1 ? top : max(top, searchFrom - geometry.containerHeight)
        return .continue(.recover(pageOffsetY: pageOffsetY))
    }
    // swiftlint:enable function_parameter_count function_default_parameter_at_end

    static func unrealizedEndRecoveryMayFollowBack(
        isInteracting: Bool,
        userIsScrolledAway: Bool,
        isFollowing: Bool
    ) -> Bool {
        !isInteracting && !userIsScrolledAway && !isFollowing
    }

    enum UnrealizedEndRecoveryReason: String, Equatable {
        case cancelled
        case gaveUp
        case noCorrectionNeeded
        case notAttempted
        case recovered
        case recovering
        case unverified
        case yieldedToUser
    }

    struct UnrealizedEndRecoveryReport: Equatable {
        let reason: UnrealizedEndRecoveryReason
        let corrections: Int
        let episodes: Int
        let endRealized: Bool

        var summary: String {
            "endRecovery=\(reason.rawValue) corrections=\(corrections) episodes=\(episodes) endRealized=\(endRealized)"
        }
    }

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
