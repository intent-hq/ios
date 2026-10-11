import SwiftUI

extension ConversationTranscriptView {
    #if DEBUG
    /// Keyboard frames are screen coordinates, not the transcript's occluded height.
    /// Read only the geometry/timing keys; never log the notification's entire payload.
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

    /// Debug device tracing for question/keyboard teardown. Never includes
    /// conversation content or backend identifiers, and does no work in Release.
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

    /// Re-checks the live scroll view once the geometry has had time to
    /// settle (a bounce or a mid-animation frame reads past the end too) and
    /// clamps the offset back to the bottom once two checks agree; a viewport
    /// still bouncing or re-laying out is checked again after it settles,
    /// since the past-end edge has already fired and will not fire twice. A
    /// programmatic follow in flight is deferred the same way so the clamp
    /// cannot land mid-animation. Without a scroll view to clamp, a following
    /// viewport is pinned back through SwiftUI's own layout instead; the pin
    /// is never broken for a blank band the user did not scroll to.
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

    /// A follow is in flight from its request until its landing is verified;
    /// an unrealized-end correction on its way back to the end counts too
    /// (the lifecycle's viewport owner), and so does the Go to End tap until
    /// its request is made.
    var isFollowing: Bool {
        scrollState.isFollowing
    }

    func cancelPastEndRePin() {
        scrollState.pastEndRePinTask?.cancel()
        scrollState.pastEndRePinTask = nil
    }

    /// A footer row appearing or disappearing under the transcript resizes its
    /// container while UIKit keeps `contentOffset`, so at rest at the bottom
    /// the last rows slide under the new row and the geometry reads scrolled
    /// away (#272). While following, the viewport is pinned straight back to
    /// the bottom and a follow in flight is restarted so it targets the new
    /// bottom; the edge this geometry carries is recorded but not applied,
    /// the pinned geometry that follows carries the real one. The pin goes
    /// through SwiftUI's own layout: when this action runs the UIScrollView's
    /// bounds still read the old height, so an offset computed from it lands
    /// at the old bottom. Under the finger or decelerating, the pin is
    /// deferred to a settle re-check and the edge is applied as usual (see
    /// `ConversationTranscriptScrollPolicy.containerHeightChangeDecision`).
    /// Recovery owns its page-up until following back, so container pins
    /// wait for that ownership to end instead of undoing the correction.
    /// A pin issued is re-checked on settle too: a resize animated over
    /// several frames (the keyboard) pins on each of them against a lazy
    /// stack still re-estimating its rows, and could leave the viewport far
    /// from the bottom with the away edge consumed here (#276). Scrolled
    /// away, the content under the reader already stays put (the container
    /// resizes at its bottom edge). Returns false when the edge is to be
    /// applied as usual.
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

    /// Re-checks the viewport once the container resize has had time to
    /// settle — a re-pin deferred while interacting, or the last of the
    /// per-frame pins of an animated resize — and re-checks again while the
    /// gesture has not settled. Short of the bottom inside the band while
    /// still following, the viewport is followed there through the ordinary
    /// automatic follow, which re-validates the geometry when it runs; past
    /// the threshold with no gesture, the resize displaced it and it is
    /// pinned straight back through a forced follow, whose landing is
    /// verified against the live scroll view (#276). The gesture predicate
    /// includes the SwiftUI phase: UIKit clears its deceleration flag a
    /// moment before the phase ending records where the fling left the
    /// viewport, and a fling past the threshold must not be snapped back.
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

    /// A band-observer edge (or streaming ending) on a pinned, settled
    /// transcript can be a short transcript that grew past one page and came
    /// to rest a line or two short of the end (#346), or growth past the
    /// band whose immediate re-pin has yet to be validated (see
    /// `ConversationTranscriptScrollPolicy.shouldRecheckBottomBandAfterEdge`).
    /// A follow in flight defers the re-check rather than dropping it. It is
    /// scheduled only from those two sources, never from a follow draining:
    /// a follow that lands a rounding error short would otherwise re-check
    /// and re-scroll itself without bound.
    func scheduleBottomBandRePinIfNeeded(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        guard ConversationTranscriptScrollPolicy.shouldRecheckBottomBandAfterEdge(
            isInteracting: isUserInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return }
        scheduleBottomBandRePin(proxy: proxy)
    }

    /// Re-checks the live distance once the geometry has had time to settle
    /// (the rows the edge's growth realized may still be laying out), and
    /// re-checks again while a gesture or a follow is in progress; a viewport
    /// still following that rests short of the bottom is followed there
    /// through the ordinary automatic follow, which re-validates the
    /// geometry when it runs (and past the band re-pins it as growth when
    /// it drains).
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

    /// Applies a geometry edge to `userIsScrolledAway` under the rule that
    /// only a gesture may break the pin (see
    /// `ConversationTranscriptScrollPolicy.scrolledAwayTransition`), and
    /// follows a pinned viewport that content grew under straight back to
    /// the bottom. The owned follow defers scrolling until layout settles
    /// and bounds its corrections; scrolling synchronously here can loop
    /// while expanded lazy rows change size. `isInteracting` defaults to the live
    /// gesture state; a phase ending passes true for its final sample. The
    /// takeover latch is released against the live state, so the phase
    /// ending pinned releases it at once. An at-bottom edge over an
    /// unrealized end row clears nothing (#338): the row realizing replays
    /// the live edge (see the marker's `onAppear`).
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
        // A history prepend's coarse restoration can briefly cross the bottom
        // band. That layout is not a user returning to the tail (#711). Keep
        // the reading position until the page settles; gestures and explicit
        // follows still take ownership immediately.
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

    /// The one gesture predicate every scrolled-away and forced-follow
    /// decision reads: the UIScrollView flags once the finder resolved, or
    /// the SwiftUI scroll phase, which also covers a gesture on a transcript
    /// whose scroll view the finder has not resolved yet.
    var isUserInteracting: Bool {
        scrollMomentumProxy.isInteracting || scrollState.isUserScrollPhase
    }

    /// Applies the live distance as a geometry edge (see
    /// `applyScrolledAwayEdge`), for the moments the geometry observer's
    /// edges were suppressed or may have been dropped: a follow draining, or
    /// the user taking over from a forced follow.
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
