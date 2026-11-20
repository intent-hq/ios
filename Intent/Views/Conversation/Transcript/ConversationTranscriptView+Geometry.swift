import SwiftUI

extension ConversationTranscriptView {
    #if DEBUG
    func logKeyboardGeometry(_ event: String, notification: Notification) {
        let info = notification.userInfo
        let begin = (info?[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue
        let end = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        let curve = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
        let isLocal = info?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool
        logScrollGeometry(
            "[QUESTION] keyboard \(event) beginScreen=\(String(describing: begin)) endScreen=\(String(describing: end))"
                + " beginHeight=\(String(describing: begin?.height)) endHeight=\(String(describing: end?.height))"
                + " duration=\(String(describing: duration)) curve=\(String(describing: curve)) local=\(String(describing: isLocal))"
        )
    }
    #endif

    func logScrollGeometry(_ event: @autoclosure () -> String) {
        #if DEBUG
        let owner: String
        switch lifecycle.owner {
        case .idle: owner = "idle"
        case .follow(_, let forced): owner = forced ? "forced-follow" : "follow"
        case .recovery: owner = "recovery"
        }
        let geometry = scrollMomentumProxy.restingGeometry
        AppLog.userInterface.debug(
            "[SCROLL] \(event()) geometry=\(String(describing: geometry))"
                + " distanceToBottom=\(String(describing: geometry?.distanceToBottom))"
                + " endRealized=\(lifecycle.isEndRealized) owner=\(owner) following=\(isFollowing)"
                + " gesture=\(isUserInteracting) away=\(userIsScrolledAway) positioned=\(hasInitiallyScrolled)"
        )
        #endif
    }

    func scheduleRePinIfRestingPastEnd(
        proxy: ScrollViewProxy,
        confirming: ScrollViewMomentumProxy.RestingGeometry? = nil
    ) {
        guard lifecycle.isVisible else { return }
        scrollState.pastEndRePinTask?.cancel()
        scrollState.pastEndRePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled, lifecycle.isVisible else { return }
            scrollState.pastEndRePinTask = nil
            let outcome = scrollMomentumProxy.rePinIfRestingPastEnd(
                confirming: confirming,
                isFollowing: isFollowing
            )
            switch outcome {
            case .deferred(let geometry):
                scheduleRePinIfRestingPastEnd(proxy: proxy, confirming: geometry)
            case .unavailable:
                if shouldFollowToBottom {
                    proxy.scrollTo("scroll-bottom", anchor: .bottom)
                }
            case .rePinned, .notPastEnd:
                break
            }
        }
    }

    var isFollowing: Bool {
        scrollState.isFollowing
    }

    func cancelPastEndRePin() {
        scrollState.pastEndRePinTask?.cancel()
        scrollState.pastEndRePinTask = nil
    }

    func rePinAfterContainerHeightChange(
        from oldContainerHeight: CGFloat,
        to newContainerHeight: CGFloat,
        proxy: ScrollViewProxy
    ) -> Bool {
        guard lifecycle.isVisible else { return false }
        recordDemoRecoveryResize(from: oldContainerHeight, to: newContainerHeight)
        if oldContainerHeight != newContainerHeight {
            logScrollGeometry("container-height \(oldContainerHeight)->\(newContainerHeight)")
        }
        let recoveryOwnsViewport: Bool
        switch lifecycle.owner {
        case .recovery: recoveryOwnsViewport = true
        case .idle, .follow: recoveryOwnsViewport = false
        }
        switch ConversationTranscriptScrollPolicy.containerHeightChangeDecision(
            oldContainerHeight: oldContainerHeight,
            newContainerHeight: newContainerHeight,
            isInteracting: scrollMomentumProxy.isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            recoveryOwnsViewport: recoveryOwnsViewport
        ) {
        case .none:
            return false
        case .deferred:
            scheduleDeferredContainerRePin(proxy: proxy)
            return false
        case .rePin:
            proxy.scrollTo("scroll-bottom", anchor: .bottom)
            if case .follow(_, let forced) = lifecycle.owner {
                scrollToBottom(proxy: proxy, forced: forced)
            }
            scheduleDeferredContainerRePin(proxy: proxy)
            return true
        case .follow:
            return false
        }
    }

    private func scheduleDeferredContainerRePin(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        scrollState.containerRePinTask?.cancel()
        scrollState.containerRePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled, lifecycle.isVisible else { return }
            scrollState.containerRePinTask = nil
            logScrollGeometry("container-settle-check")
            switch ConversationTranscriptScrollPolicy.deferredContainerRePinDecision(
                distanceToBottom: scrollMomentumProxy.distanceToBottom,
                isInteracting: isUserInteracting,
                isFollowing: isFollowing,
                hasInitiallyScrolled: hasInitiallyScrolled,
                userIsScrolledAway: userIsScrolledAway
            ) {
            case .deferred:
                scheduleDeferredContainerRePin(proxy: proxy)
            case .follow:
                AppLog.userInterface.debug("[SCROLL] Container changed; following to the bottom after settle")
                scrollToBottom(proxy: proxy, forced: false)
            case .rePin:
                AppLog.userInterface.debug("[SCROLL] Container change left the viewport away; pinning back after settle")
                scrollToBottom(proxy: proxy, forced: true, animated: false)
            case .none:
                break
            }
        }
    }

    func cancelDeferredContainerRePin() {
        scrollState.containerRePinTask?.cancel()
        scrollState.containerRePinTask = nil
    }

    func scheduleBottomBandRePinIfNeeded(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        guard ConversationTranscriptScrollPolicy.shouldRecheckBottomBandAfterEdge(
            isInteracting: isUserInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return }
        scheduleBottomBandRePin(proxy: proxy)
    }

    private func scheduleBottomBandRePin(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        scrollState.bottomBandRePinTask?.cancel()
        scrollState.bottomBandRePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled, lifecycle.isVisible else { return }
            scrollState.bottomBandRePinTask = nil
            switch ConversationTranscriptScrollPolicy.bottomBandRePinDecision(
                distanceToBottom: scrollMomentumProxy.distanceToBottom,
                isInteracting: isUserInteracting,
                isFollowing: isFollowing,
                hasInitiallyScrolled: hasInitiallyScrolled,
                userIsScrolledAway: userIsScrolledAway
            ) {
            case .deferred:
                scheduleBottomBandRePin(proxy: proxy)
            case .rePin:
                AppLog.userInterface.debug(
                    "[SCROLL] Pinned viewport rests short of the bottom after settle; following to the bottom"
                )
                scrollToBottom(proxy: proxy, forced: false)
            case .none:
                break
            }
        }
    }

    func cancelBottomBandRePin() {
        scrollState.bottomBandRePinTask?.cancel()
        scrollState.bottomBandRePinTask = nil
    }

    func applyScrolledAwayEdge(geometryAway: Bool, proxy: ScrollViewProxy) {
        applyScrolledAwayEdge(
            geometryAway: geometryAway,
            isInteracting: isUserInteracting,
            proxy: proxy
        )
    }

    func applyScrolledAwayEdge(
        geometryAway: Bool,
        isInteracting: Bool,
        proxy: ScrollViewProxy
    ) {
        guard lifecycle.isVisible else { return }
        if userIsScrolledAway, scrollState.olderMessagesTask != nil, !isInteracting, !isFollowing { return }
        let next = ConversationTranscriptScrollPolicy.scrolledAwayTransition(
            current: userIsScrolledAway,
            geometryAway: geometryAway,
            isInteracting: isInteracting,
            isEndRealized: lifecycle.isEndRealized
        )
        if next != userIsScrolledAway {
            scrollState.userIsScrolledAway = next
        }
        scrollState.forcedFollowTakenOverByGesture = ConversationTranscriptScrollPolicy.forcedFollowTakeoverLatch(
            current: scrollState.forcedFollowTakenOverByGesture,
            geometryAway: geometryAway,
            isInteracting: isUserInteracting
        )
        if ConversationTranscriptScrollPolicy.shouldRePinAfterContentGrowth(
            geometryAway: geometryAway,
            isInteracting: isInteracting,
            isFollowing: isFollowing,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: next
        ) {
            AppLog.userInterface.debug("[SCROLL] Content grew under the pinned viewport; re-pinning to the bottom")
            scrollToBottom(proxy: proxy, forced: true, animated: false)
        }
    }

    var isUserInteracting: Bool {
        scrollMomentumProxy.isInteracting || scrollState.isUserScrollPhase
    }

    private func applyLiveScrolledAwayEdge(proxy: ScrollViewProxy) {
        applyLiveScrolledAwayEdge(isInteracting: isUserInteracting, proxy: proxy)
    }

    func applyLiveScrolledAwayEdge(isInteracting: Bool, proxy: ScrollViewProxy) {
        guard let distance = scrollMomentumProxy.distanceToBottom else { return }
        applyScrolledAwayEdge(
            geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: distance),
            isInteracting: isInteracting,
            proxy: proxy
        )
    }
}
