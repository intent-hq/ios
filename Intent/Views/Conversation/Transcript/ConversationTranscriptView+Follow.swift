import SwiftUI

extension ConversationTranscriptView {
    @discardableResult
    func send(_ event: Lifecycle.Event, proxy: ScrollViewProxy, animated: Bool = true) -> [Lifecycle.Effect] {
        let animated = ConversationTranscriptScrollPolicy.animatesFollow(requested: animated, reduceMotion: reduceMotion)
        recordDemoRecoveryResizeFollowBack(event)
        let (state, effects) = Lifecycle.transition(lifecycle, event)
        traceEvent("RecoveryTransition", "event=\(event) visibility=\(state.visibility) ownerBefore=\(lifecycle.owner) ownerAfter=\(state.owner)"
            + " armed=\(String(describing: state.armedRecovery)) fallback=\(state.fallback)")
        traceEvent("RecoveryEffects", "event=\(event) effects=\(effects)")
        if state != lifecycle || !effects.isEmpty {
            traceSnapshot("lifecycleTransition")
        }
        #if DEBUG
        let traceTransition = state.owner != lifecycle.owner || state.isEndRealized != lifecycle.isEndRealized
        #endif
        scrollState.lifecycle = state
        #if DEBUG
        if traceTransition { logScrollGeometry("lifecycle-changed") }
        #endif
        for effect in effects {
            perform(effect, proxy: proxy, animated: animated)
        }
        return effects
    }

    private func perform(_ effect: Lifecycle.Effect, proxy: ScrollViewProxy, animated: Bool) {
        switch effect {
        case let .startFollowTask(token, forced):
            startFollowTask(token, forced: forced, animated: animated, proxy: proxy)
        case .cancelFollowTask(let token):
            scrollState.followTasks[token]?.cancel()
            scrollState.followTasks[token] = nil
            scrollState.isScrollingToBottom = false
        case .startRecoveryTask(let token):
            scrollState.unrealizedEndRecoveryEpisodes += 1
            scrollState.unrealizedEndRecoveryCorrections = 0
            scrollState.lastUnrealizedEndRecoveryReport = nil
            scrollState.recoveryTasks[token] = Task { @MainActor in
                await runUnrealizedEndRecovery(token, proxy: proxy)
            }
        case .cancelRecoveryTask(let token):
            cancelRecoveryTask(token)
        case .scrollToEnd:
            issueScrollToBottom(proxy: proxy, animated: animated)
        case .pageUp(let offsetY):
            scrollMomentumProxy.pageTo(offsetY: offsetY)
        case .replayLiveEdge(let sample):
            applyLiveScrolledAwayEdge(isInteracting: sample.isInteracting(live: isUserInteracting), proxy: proxy)
        case .showGoToEnd:
            scrollState.userIsScrolledAway = true
        case let .recordRecoveryOutcome(terminal, corrections):
            scrollState.unrealizedEndRecoveryCorrections = corrections
            recordUnrealizedEndRecoveryReport(outcome: terminal, cancelled: false)
        case .log(let message):
            AppLog.userInterface.debug(message)
        }
    }

    private func startFollowTask(_ token: Lifecycle.FollowToken, forced: Bool, animated: Bool, proxy: ScrollViewProxy) {
        if forced {
            scrollState.isScrollingToBottom = true
            scrollState.forcedFollowRequestCount += 1
            scrollState.lastForcedFollowOutcome = nil
            scrollState.lastForcedFollowCorrections = 0
        }
        scrollState.followTasks[token] = Task { @MainActor in
            await runFollow(token, forced: forced, animated: animated, proxy: proxy)
        }
    }

    func followGoToEndRequest(proxy: ScrollViewProxy) {
        let animated = ConversationTranscriptScrollPolicy.shouldAnimateGoToEnd(
            geometry: scrollMomentumProxy.restingGeometry
        )
        scrollToBottom(proxy: proxy, forced: true, animated: animated)
    }

    func followStreamingDeltaIfDrifted(proxy: ScrollViewProxy) {
        guard ConversationTranscriptScrollPolicy.shouldFollowStreamingDelta(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            distanceToBottom: scrollMomentumProxy.distanceToBottom,
            now: ProcessInfo.processInfo.systemUptime,
            lastFollowAt: scrollState.lastFollowToBottomAt
        ) else { return }
        scrollToBottom(proxy: proxy, forced: false)
    }

    func takeOverPendingFollowIfGesture(proxy: ScrollViewProxy) {
        takeOverPendingFollowIfGesture(isInteracting: isUserInteracting, proxy: proxy)
    }

    func takeOverPendingFollowIfGesture(isInteracting: Bool, proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        scrollState.observeViewportGesture(isInteracting: isInteracting)
        if isInteracting {
            scrollState.preservePresentedViewport(distanceToBottom: scrollMomentumProxy.distanceToBottom)
        }
        guard ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
            isInteracting: isInteracting,
            isFollowing: isFollowing
        ) else { return }
        cancelPendingFollowOnTakeover(proxy: proxy)
    }

    func cancelPendingFollowOnTakeover(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        if case .follow(_, forced: true) = lifecycle.owner {
            scrollState.forcedFollowTakenOverByGesture = true
        }
        scrollState.isScrollingToBottom = false
        send(.followCancelledByGesture, proxy: proxy)
    }

    func claimViewportForExplicitFollow(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        scrollState.retireViewportRestoration()
        scrollState.forcedFollowTakenOverByGesture = false
        scrollState.isUserScrollPhase = false
        send(.explicitClaim, proxy: proxy)
    }

    func scrollToBottom(proxy: ScrollViewProxy, forced: Bool, animated: Bool = true) {
        guard lifecycle.isVisible else { return }
        if forced, !ConversationTranscriptScrollPolicy.shouldHonorForcedFollow(
            takenOverByGesture: scrollState.forcedFollowTakenOverByGesture
        ) {
            AppLog.userInterface.debug("[SCROLL] Forced follow refused: a gesture took over the last one")
            traceEvent("FollowSkipped", "reason=gestureTakeover forced=\(forced)")
            return
        }
        scrollState.lastFollowToBottomAt = ProcessInfo.processInfo.systemUptime
        send(.followRequested(forced: forced), proxy: proxy, animated: animated)
    }

    private func runFollow(
        _ token: Lifecycle.FollowToken, forced: Bool, animated: Bool, proxy: ScrollViewProxy
    ) async {
        try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.scrollDebounceMilliseconds))
        guard !Task.isCancelled else { return }
        let shouldExecute = ConversationTranscriptScrollPolicy.shouldExecuteFollow(
            forced: forced,
            userIsScrolledAway: userIsScrolledAway,
            distanceToBottom: scrollMomentumProxy.distanceToBottom,
            isInteracting: isUserInteracting
        )
        if forced, !shouldExecute {
            scrollState.lastForcedFollowOutcome = .yieldToUser
        }
        send(.followDue(token, execute: shouldExecute), proxy: proxy, animated: animated)
        if shouldExecute {
            if forced {
                await awaitForcedFollowLanding(proxy: proxy, animated: animated)
            } else {
                try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.scrollCompletionMilliseconds))
            }
            guard !Task.isCancelled else { return }
        }
        scrollState.isScrollingToBottom = false
        scrollState.followTasks[token] = nil
        let terminal: Lifecycle.FollowTerminal
        if shouldExecute {
            terminal = .executed(forced ? scrollState.lastForcedFollowOutcome : nil)
        } else {
            terminal = forced ? .yielded : .dropped
        }
        send(.followFinished(token, terminal), proxy: proxy)
    }

    private func issueScrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let target = lifecycle.isEndRealized ? "scroll-bottom" : "transcript-tail"
        traceSnapshot("scrollToEndRequested target=\(target) animated=\(animated)")
        if animated {
            withAnimation(.easeOut(duration: Constants.Conversation.Transcript.scrollAnimationDuration)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// Polls the live scroll view until the forced follow has landed within
    /// `followLandingTolerance` of the bottom, scrolling again from short of the bottom and
    /// clamping from past the end a bounded number of times (#281, #271; see
    /// `ConversationTranscriptScrollPolicy.followLandingStep`). Ends early
    /// when the user takes over — the geometry edges then carry the gesture
    /// rule, and the live distance is applied once as the gesture's sample in
    /// case its edge was dropped — and on the timeout, leaving the pin as it
    /// is. Bails out silently when the follow is restarted (task cancelled).
    ///
    /// Each correction is judged from two fresh reads taken after its scroll
    /// has had its animation's duration to move: a poll that reused the
    /// pre-correction rest as `previous` before a frame rendered read the
    /// same geometry twice, spent the next correction on it and gave up with
    /// the viewport still on its way (#305).
    private func awaitForcedFollowLanding(proxy: ScrollViewProxy, animated: Bool) async {
        let deadline = ContinuousClock.now
            + .milliseconds(Constants.Conversation.Transcript.followLandingTimeoutMilliseconds)
        var correctionsLeft = Constants.Conversation.Transcript.followLandingRetries
        var previous: ScrollViewMomentumProxy.RestingGeometry?
        while true {
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.followLandingPollMilliseconds))
            guard !Task.isCancelled else { return }
            let geometry = scrollMomentumProxy.restingGeometry
            let step = ConversationTranscriptScrollPolicy.followLandingStep(
                geometry: geometry,
                previous: previous,
                isInteracting: isUserInteracting,
                correctionsLeft: correctionsLeft,
                timedOut: ContinuousClock.now >= deadline,
                userIsScrolledAway: userIsScrolledAway
            )
            previous = geometry
            traceEvent("FollowLanding", "step=\(step) remaining=\(correctionsLeft) geometry=\(String(describing: geometry))")
            switch step {
            case .continue(.settling):
                continue
            case .continue(.scrollAgain):
                correctionsLeft -= 1
                scrollState.lastForcedFollowCorrections += 1
                AppLog.userInterface.debug("[SCROLL] Forced follow landed short of the bottom, scrolling again")
                issueScrollToBottom(proxy: proxy, animated: animated)
                previous = nil
                if animated {
                    try? await Task.sleep(for: .seconds(Constants.Conversation.Transcript.scrollAnimationDuration))
                    guard !Task.isCancelled else { return }
                }
            case .continue(.clampPastEnd):
                correctionsLeft -= 1
                scrollState.lastForcedFollowCorrections += 1
                AppLog.userInterface.debug("[SCROLL] Forced follow landed past the end, clamping")
                _ = scrollMomentumProxy.rePinIfRestingPastEnd(confirming: geometry)
                previous = nil
            case .finish(.yieldToUser):
                scrollState.lastForcedFollowOutcome = .yieldToUser
                applyLiveScrolledAwayEdge(isInteracting: true, proxy: proxy)
                return
            case .finish(let terminal):
                scrollState.lastForcedFollowOutcome = terminal
                return
            }
        }
    }
}
