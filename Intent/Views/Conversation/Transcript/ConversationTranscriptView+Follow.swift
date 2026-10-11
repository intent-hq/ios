import SwiftUI

extension ConversationTranscriptView {
    /// The one transition of the follow / unrealized-end recovery lifecycle
    /// (see `ConversationTranscriptRecoveryLifecycle`): the next state is
    /// stored, then every effect is executed in order. `animated` is the
    /// animation of the `.scrollToEnd` the event issues and of the follow a
    /// `.startFollowTask` begins: a follow's own, none for a recovery's
    /// corrections. Returns the effects.
    @discardableResult
    func send(_ event: Lifecycle.Event, proxy: ScrollViewProxy, animated: Bool = true) -> [Lifecycle.Effect] {
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

    /// Executes one lifecycle effect against the live view. A forced follow
    /// starting raises `isScrollingToBottom` and resets its demo report; a
    /// follow cancelled releases the flag (its drain releases it itself, see
    /// `runFollow`).
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

    /// A gesture observed while a follow is pending — a user-driven scroll
    /// phase beginning, or a geometry edge under UIKit tracking, dragging or
    /// deceleration — takes it over there and then (see
    /// `ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow`).
    /// Waiting for the task to come due is not enough: the gesture's final
    /// away edge can be dropped and its ending delivered first, and the
    /// check would then read idle and pinned and scroll the user back.
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

    /// The user taking over consumes whatever follow is still pending: an
    /// automatic one in its debounce, a forced one in its debounce or its
    /// landing loop, or an unrealized-end correction between its page up and
    /// its follow back. Every forced follow is requested from a pinned viewport,
    /// so the gesture came after the request and wins — the request is not
    /// kept for after the gesture ends, and its takeover is latched so a
    /// forced follow content raises meanwhile does not revive it. The
    /// lifecycle cancels whichever owner and armed recovery there is, and
    /// shows Go to End for a give-up it had transferred to the cancelled
    /// follow; the execution and landing checks cover the frame before this
    /// runs. Go to End tapped afterwards is a fresh request.
    func cancelPendingFollowOnTakeover(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        if case .follow(_, forced: true) = lifecycle.owner {
            scrollState.forcedFollowTakenOverByGesture = true
        }
        scrollState.isScrollingToBottom = false
        send(.followCancelledByGesture, proxy: proxy)
    }

    /// An explicit request — Go to End, or the user's own message — takes
    /// the viewport back from any gesture: the takeover latch is released
    /// and the SwiftUI phase is no longer the gesture's, so a phase ending
    /// delivered after the request (the fling it stopped, the tap that sent
    /// the message lifting) is not applied as the gesture's final sample and
    /// does not take the request's follow over. An unrealized-end recovery
    /// in flight is cancelled too: the request's follow owns the viewport.
    func claimViewportForExplicitFollow(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        scrollState.retireViewportRestoration()
        scrollState.forcedFollowTakenOverByGesture = false
        scrollState.isUserScrollPhase = false
        send(.explicitClaim, proxy: proxy)
    }

    /// Stamps the request time up front so deltas arriving inside the debounce
    /// window are rejected by the policy instead of restarting the debounce.
    /// Forced follows are never preempted by automatic ones (the lifecycle
    /// refuses the request); a user gesture cancels either at once (see
    /// `takeOverPendingFollowIfGesture`), and a forced follow raised while a
    /// gesture's takeover is latched is refused (see
    /// `ConversationTranscriptScrollPolicy.shouldHonorForcedFollow`). A
    /// request over a pending follow replaces it: the lifecycle cancels the
    /// old task and starts the new one (see `runFollow`), which inherits a
    /// give-up the recovery had transferred to the old.
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

    /// One follow from its debounce to its terminal. Automatic follows are
    /// re-validated by the policy once the debounce elapses, so a user who
    /// scrolled away meanwhile is not snapped back. A forced follow keeps
    /// `isScrollingToBottom` raised for its whole duration and is complete
    /// only once the live geometry confirms its landing (see
    /// `awaitForcedFollowLanding`), or yields when the user is interacting
    /// — or already scrolled away — as it comes due. An automatic follow
    /// rides the bottom anchor and just waits out its animation; growth
    /// edges are suppressed while it is in flight, so when it drains —
    /// executed or dropped — the lifecycle replays the live distance once as
    /// the edge it may have swallowed: content that grew past the band
    /// during the debounce with no gesture is re-pinned, not left short with
    /// Go to End hidden. The terminal also resolves a give-up the end
    /// recovery transferred to this follow (dropped or yielded over an
    /// unrealized end row, Go to End is shown and no edge replayed) and
    /// re-arms the recovery when the follow executed over a still-unrealized
    /// end row. Bails out silently when cancelled: the lifecycle that
    /// cancelled it has resolved its state.
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
        // The tail is a direct lazy-stack child, so SwiftUI can realize it
        // while its nested footer is absent. Both targets end at the footer.
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
