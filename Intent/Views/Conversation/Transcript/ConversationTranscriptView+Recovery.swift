import SwiftUI

extension ConversationTranscriptView {
    func cancelRecoveryTask(_ token: Lifecycle.RecoveryToken) {
        if let task = scrollState.recoveryTasks[token] {
            task.cancel()
            scrollState.recoveryTasks[token] = nil
            recordUnrealizedEndRecoveryReport(outcome: nil, cancelled: true)
        }
    }

    /// Verifies, once the geometry has settled, that a following viewport
    /// rests on realized rows, and recovers a blank one (#338): the lazy
    /// stack can realize no rows at all under an offset that still reads
    /// "at bottom" — the container re-pin's `scrollTo` after a footer row
    /// landed did exactly that on a transcript whose last rows re-measure —
    /// so every geometry-driven path stays silent. Armed by the lifecycle
    /// when the end row derealizes, or when a follow drains with the end
    /// row still unrealized (the row it cancelled the recovery over yields
    /// no new edge); corrections search progressively above prior attempts
    /// so rows realize, then follow back to the end, and
    /// the loop re-verifies from two fresh reads, a bounded number of times
    /// (see `ConversationTranscriptScrollPolicy.unrealizedEndRecoveryStep`).
    /// The loop keeps the deadline and the correction budget and reports
    /// each step and its terminal to the lifecycle under its token, which
    /// decides what the step may do: a gesture or a follow in flight is
    /// waited out; a user who rests away ends it; a gesture or a follow
    /// that claims the viewport while a correction has it paged up cancels
    /// it, and the follow back re-checks the claim once the rows have
    /// realized rather than scroll over it. A correction in flight owns the
    /// viewport as a follow does, so the growth re-pin stays suppressed
    /// until the terminal replays the live edge — or, once the budget is
    /// spent over a still-unrealized row, shows Go to End rather than
    /// scroll blind, deferring that to the follow that owns the viewport if
    /// one does. It is not a forced follow, so the follow's report is left
    /// as it is; the recovery reports next to it under `--demo-data`. A
    /// verification already running keeps its budget: it reads the end
    /// row's current state at every poll, so re-arming it would only reset
    /// the bound.
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

    /// The step read the live geometry this same pass, so the page up found
    /// the scroll view; the rows realize under the paged-up offset before
    /// the follow back re-checks the claim. Returns false when the loop
    /// ends here: cancelled during the settle, or yielded to the user.
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

    /// Records how the episode ended, with the corrections it spent and
    /// the end row's realization at this moment, so every terminal path —
    /// resolved on any terminal, or cancelled — is observable under
    /// `--demo-data` (see `ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport`).
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
