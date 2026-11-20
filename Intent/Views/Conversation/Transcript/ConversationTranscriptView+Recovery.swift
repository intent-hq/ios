import SwiftUI

extension ConversationTranscriptView {
    func cancelRecoveryTask(_ token: Lifecycle.RecoveryToken) {
        if let task = scrollState.recoveryTasks[token] {
            task.cancel()
            scrollState.recoveryTasks[token] = nil
            recordUnrealizedEndRecoveryReport(outcome: nil, cancelled: true)
        }
    }

    func runUnrealizedEndRecovery(_ token: Lifecycle.RecoveryToken, proxy: ScrollViewProxy) async {
        let deadline = ContinuousClock.now + .milliseconds(Constants.Conversation.Transcript.followLandingTimeoutMilliseconds)
        var correctionsLeft = Constants.Conversation.Transcript.followLandingRetries
        var previous: ScrollViewMomentumProxy.RestingGeometry?
        var previousPageOffsetY: CGFloat?
        while true {
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled else { return }
            let geometry = scrollMomentumProxy.restingGeometry
            let step = ConversationTranscriptScrollPolicy.unrealizedEndRecoveryStep(
                geometry: geometry,
                previous: previous,
                isEndRealized: lifecycle.isEndRealized,
                isInteracting: isUserInteracting,
                isFollowing: followOwnsViewport || isScrollingToBottom,
                hasInitiallyScrolled: hasInitiallyScrolled,
                userIsScrolledAway: userIsScrolledAway,
                correctionsLeft: correctionsLeft,
                correctionsSpent: scrollState.unrealizedEndRecoveryCorrections,
                previousPageOffsetY: previousPageOffsetY,
                timedOut: ContinuousClock.now >= deadline
            )
            previous = geometry
            traceEvent("RecoveryStep", "token=\(token) step=\(step) remaining=\(correctionsLeft) previousPage=\(String(describing: previousPageOffsetY)) geometry=\(String(describing: geometry))")
            switch step {
            case .continue(let continuation):
                let effects = send(.recoveryStep(token, continuation), proxy: proxy, animated: false)
                switch continuation {
                case .settling:
                    continue
                case .followToEnd:
                    guard !effects.isEmpty else { continue }
                    correctionsLeft -= 1
                    scrollState.unrealizedEndRecoveryCorrections += 1
                case .recover(let pageOffsetY):
                    guard !effects.isEmpty else { continue }
                    previousPageOffsetY = pageOffsetY
                    correctionsLeft -= 1
                    scrollState.unrealizedEndRecoveryCorrections += 1
                    guard await followBackAfterPageUp(token, proxy: proxy) else { return }
                }
                previous = nil
            case .finish(let terminal):
                scrollState.recoveryTasks[token] = nil
                send(
                    .recoveryFinished(token, terminal, corrections: scrollState.unrealizedEndRecoveryCorrections),
                    proxy: proxy
                )
                return
            }
        }
    }

    private func followBackAfterPageUp(_ token: Lifecycle.RecoveryToken, proxy: ScrollViewProxy) async -> Bool {
        try? await Task.sleep(
            for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds)
        )
        guard !Task.isCancelled else { return false }
        let mayFollowBack = ConversationTranscriptScrollPolicy.unrealizedEndRecoveryMayFollowBack(
            isInteracting: isUserInteracting,
            userIsScrolledAway: userIsScrolledAway,
            isFollowing: followOwnsViewport
        )
        send(.recoveryPagedUp(token, mayFollowBack: mayFollowBack), proxy: proxy, animated: false)
        guard mayFollowBack else {
            scrollState.recoveryTasks[token] = nil
            send(
                .recoveryFinished(
                    token,
                    .yieldToUser,
                    corrections: scrollState.unrealizedEndRecoveryCorrections
                ),
                proxy: proxy
            )
            return false
        }
        return true
    }

    func recordUnrealizedEndRecoveryReport(
        outcome: ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal?,
        cancelled: Bool
    ) {
        scrollState.lastUnrealizedEndRecoveryReport = ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport(
            outcome: outcome,
            corrections: scrollState.unrealizedEndRecoveryCorrections,
            episodes: scrollState.unrealizedEndRecoveryEpisodes,
            endRealized: lifecycle.isEndRealized,
            cancelled: cancelled
        )
    }
}
