import SwiftUI

// Scroll coordination is intentionally colocated so its gesture, geometry,
// debounce, and landing state machine can be reviewed as one unit.
// swiftlint:disable file_length
struct ConversationTranscriptView: View {
    private enum Layout {
        static let transcriptRowSpacing: CGFloat = 16
        static let transcriptHorizontalPadding: CGFloat = 16
        static let transcriptTopPadding: CGFloat = 24
        static let bottomAnchorHeight: CGFloat = 8
        static let bottomAnchorPadding: CGFloat = 12
        static let goToEndSpacing: CGFloat = 4
        static let goToEndHorizontalPadding: CGFloat = 14
        static let goToEndVerticalPadding: CGFloat = 8
        static let goToEndShadowOpacity = 0.15
        static let goToEndShadowRadius: CGFloat = 4
        static let goToEndShadowYOffset: CGFloat = 2
        static let goToEndBottomPadding: CGFloat = 8
        static let thinkingIndicatorSpacing: CGFloat = 6
        static let thinkingIndicatorScale = 0.7
        static let thinkingIndicatorSide: CGFloat = 16
        static let thinkingIndicatorHorizontalPadding: CGFloat = 12
        static let thinkingIndicatorVerticalPadding: CGFloat = 4
        static let suggestedPromptSpacing: CGFloat = 8
        static let suggestedPromptHorizontalPadding: CGFloat = 14
        static let suggestedPromptVerticalPadding: CGFloat = 10
        static let suggestedPromptBackgroundOpacity = 0.4
        static let suggestedPromptCornerRadius: CGFloat = 10
        static let suggestedPromptBorderOpacity = 0.3
        static let suggestedPromptBorderWidth: CGFloat = 1
        static let truncationBannerSpacing: CGFloat = 8
        static let truncationBannerHorizontalPadding: CGFloat = 16
        static let truncationBannerVerticalPadding: CGFloat = 12
        static let truncationBannerBackgroundOpacity = 0.5
        static let truncationBannerCornerRadius: CGFloat = 10
    }

    let viewModel: ConversationViewModel
    let scrollState: ConversationTranscriptScrollState
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private typealias Lifecycle = ConversationTranscriptRecoveryLifecycle

    private var scrollMomentumProxy: ScrollViewMomentumProxy {
        scrollState.momentumProxy
    }

    private var lifecycle: Lifecycle.State {
        scrollState.lifecycle
    }

    /// A follow is pending: in its debounce, or verifying its landing.
    private var followOwnsViewport: Bool {
        if case .follow = lifecycle.owner { return true }
        return false
    }

    private var userIsScrolledAway: Bool {
        get { scrollState.userIsScrolledAway }
        nonmutating set { scrollState.userIsScrolledAway = newValue }
    }

    private var hasInitiallyScrolled: Bool {
        get { scrollState.hasInitiallyScrolled }
        nonmutating set { scrollState.hasInitiallyScrolled = newValue }
    }

    private var initialScrollScheduled: Bool {
        get { scrollState.initialScrollScheduled }
        nonmutating set { scrollState.initialScrollScheduled = newValue }
    }

    private var isScrollingToBottom: Bool {
        get { scrollState.isScrollingToBottom }
        nonmutating set { scrollState.isScrollingToBottom = newValue }
    }

    var body: some View {
        let dividerAnchorId = viewModel.newMessagesDividerAnchorId
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                transcriptScrollView(proxy: proxy, dividerAnchorId: dividerAnchorId)

                if userIsScrolledAway {
                    goToEndButton(proxy: proxy)
                }
            }
        }
    }
}

private extension ConversationTranscriptView {
    /// The follow handlers stay gated until the entry-scroll decision finishes,
    /// so stream updates cannot yank the viewport away from the unread divider.
    /// Only discrete transitions scroll; streaming deltas ride the bottom anchor
    /// and at most re-pin a drifted viewport (see the policy). Footer rows
    /// resizing the container are handled by the geometry observation in
    /// `transcriptScrollBase`, not per source.
    private func transcriptScrollView(
        proxy: ScrollViewProxy,
        dividerAnchorId: String?
    ) -> some View {
        transcriptScrollBase(proxy: proxy, dividerAnchorId: dividerAnchorId)
            .onChange(of: viewModel.filteredMessages.count) { oldCount, newCount in
                handleMessageCountChange(from: oldCount, to: newCount, proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, isStreaming in
                if ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
                    isStreaming: isStreaming,
                    hasInitiallyScrolled: hasInitiallyScrolled,
                    userIsScrolledAway: userIsScrolledAway
                ) {
                    scrollToBottom(proxy: proxy, forced: true)
                } else if !isStreaming {
                    // The last delta and the thinking indicator leaving (or
                    // the suggested prompts arriving) can rest a short
                    // transcript short of the bottom (#346).
                    scheduleBottomBandRePinIfNeeded(proxy: proxy)
                }
            }
            .onChange(of: viewModel.store.streamingUpdateCount) { _, _ in
                followStreamingDeltaIfDrifted(proxy: proxy)
            }
            .onChange(of: viewModel.isLoading) { _, isLoading in
                if !isLoading {
                    runInitialScrollIfNeeded(proxy: proxy)
                }
            }
            .onAppear {
                // On first open the transcript mounts only after loading settles,
                // so onAppear is also an entry-scroll trigger for cached data.
                if !viewModel.isLoading {
                    runInitialScrollIfNeeded(proxy: proxy)
                }
            }
            .onChange(of: scrollMomentumProxy.hasResolvedScrollView) { _, resolved in
                if resolved {
                    handleScrollViewResolved(proxy: proxy)
                }
            }
            .onChange(of: userIsScrolledAway) { _, scrolledAway in
                let goToEndRequested = scrollState.goToEndRequested
                scrollState.goToEndRequested = false
                if scrolledAway {
                    cancelPendingFollowOnTakeover(proxy: proxy)
                } else if ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
                    goToEndRequested: goToEndRequested
                ) {
                    scrollToBottom(proxy: proxy, forced: true)
                }
            }
    }

    private func handleMessageCountChange(from oldCount: Int, to newCount: Int, proxy: ScrollViewProxy) {
        switch ConversationTranscriptScrollPolicy.messageCountChangeDecision(
            from: oldCount,
            to: newCount,
            hasInitiallyScrolled: hasInitiallyScrolled
        ) {
        case .rearmEntryScroll:
            cancelPastEndRePin()
            cancelDeferredContainerRePin()
            cancelBottomBandRePin()
            // The lifecycle and its tasks live in the parent-owned scroll
            // state, so they survive the empty view replacing this transcript.
            // Reuse the all-owner cancellation before resetting the entry
            // latches; the reset clears its gesture-specific fallback state.
            cancelPendingFollowOnTakeover(proxy: proxy)
            scrollState.rearmAfterTranscriptEmptied()
            return
        case .rePinIfPastEnd:
            scheduleRePinIfRestingPastEnd(proxy: proxy)
        case .runEntryScroll:
            if !viewModel.isLoading {
                runInitialScrollIfNeeded(proxy: proxy)
            }
            return
        case .none:
            break
        }
        let appendedUserMessage = newCount > oldCount
            && viewModel.filteredMessages.last?.role == .user
        if appendedUserMessage {
            claimViewportForExplicitFollow(proxy: proxy)
            userIsScrolledAway = false
        }
        if shouldFollowToBottom {
            scrollToBottom(proxy: proxy, forced: appendedUserMessage)
        }
    }

    private var shouldFollowToBottom: Bool {
        ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    /// The scrolled-away edge is sampled together with the container height so
    /// a footer row resizing the container and the edge that resize causes
    /// arrive in one action (#272), and with the distance band so an edge the
    /// observer drops is re-delivered at the next band crossing (#280, see
    /// `ConversationTranscriptScrollPolicy.distanceBand`).
    private struct ScrolledAwayGeometry: Equatable {
        let isScrolledAway: Bool
        let distanceBand: Int
        let containerHeight: CGFloat
    }

    // This modifier chain is one scroll-state machine: splitting it would hide
    // the ordering between gesture, geometry, and past-end observations.
    // swiftlint:disable:next function_body_length
    private func transcriptScrollBase(proxy: ScrollViewProxy, dividerAnchorId: String?) -> some View {
        ScrollView {
            LazyVStack(spacing: Layout.transcriptRowSpacing) {
                transcriptRows(proxy: proxy, dividerAnchorId: dividerAnchorId)
            }
            .padding(.horizontal, Layout.transcriptHorizontalPadding)
            .padding(.top, Layout.transcriptTopPadding)
            // Hosted on the stack itself, not a lazily realized row, so the
            // UIScrollView is found regardless of which rows exist.
            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        .accessibilityIdentifier("transcript.scrollView")
        .demoAccessibilityValue(
            ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(
                outcome: scrollState.lastForcedFollowOutcome,
                corrections: scrollState.lastForcedFollowCorrections,
                endRecovery: unrealizedEndRecoveryDemoReport.summary
            )
        )
        .demoEndDerealization(
            triggerFile: DemoFixtures.configuredEndDerealizationTriggerFile,
            onTrigger: withdrawEndRowForDemo,
            onGeometryChange: restoreDerealizedEndIfMoved
        )
        // Keyboard dismissal is installed by ScrollViewFinder. A SwiftUI tap
        // gesture here would starve Textual's UIKit link-tap recognizer.
        .onScrollGeometryChange(for: ScrolledAwayGeometry.self) { geometry in
            // `containerSize` excludes the safe-area insets while
            // `contentOffset` includes them, so measuring with it reads the
            // top inset (the navigation bar) at rest at the bottom.
            // `visibleRect` spans the full bounds, matching UIScrollView.
            let distance = ConversationTranscriptScrollPolicy.distanceToBottom(
                contentHeight: geometry.contentSize.height,
                contentOffsetY: geometry.contentOffset.y,
                containerHeight: geometry.visibleRect.height,
                bottomInset: geometry.contentInsets.bottom
            )
            return ScrolledAwayGeometry(
                isScrolledAway: ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: distance),
                distanceBand: ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: distance),
                containerHeight: geometry.visibleRect.height
            )
        } action: { old, new in
            takeOverPendingFollowIfGesture(proxy: proxy)
            if rePinAfterContainerHeightChange(
                from: old.containerHeight, to: new.containerHeight, proxy: proxy
            ) { return }
            applyScrolledAwayEdge(geometryAway: new.isScrolledAway, proxy: proxy)
            scheduleBottomBandRePinIfNeeded(proxy: proxy)
        }
        // A user-driven phase beginning takes over whatever follow is pending
        // (see `takeOverPendingFollowIfGesture`). A gesture's last geometry
        // edge can arrive after UIKit has cleared its deceleration flag, and
        // the band observer above drops a flip that reverses within one
        // layout pass (#280); the phase ending is one authoritative sample of
        // where the gesture left the viewport. An explicit follow that cut
        // the gesture short (Go to End stopping a fling, the tap that sent a
        // message) owns the flag instead.
        .onScrollPhaseChange { oldPhase, newPhase, context in
            scrollState.isUserScrollPhase = newPhase.isUserDriven
            if newPhase.isUserDriven {
                takeOverPendingFollowIfGesture(isInteracting: true, proxy: proxy)
            }
            guard oldPhase.isUserDriven, !newPhase.isUserDriven, !isScrollingToBottom else { return }
            let distance = ConversationTranscriptScrollPolicy.distanceToBottom(
                contentHeight: context.geometry.contentSize.height,
                contentOffsetY: context.geometry.contentOffset.y,
                containerHeight: context.geometry.visibleRect.height,
                bottomInset: context.geometry.contentInsets.bottom
            )
            applyScrolledAwayEdge(
                geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: distance),
                isInteracting: true,
                proxy: proxy
            )
        }
        // A viewport resting past the end of content taller than the container
        // (blank band under the last message) reads "at bottom" above, so it
        // is watched separately and re-pinned (#271).
        .onScrollGeometryChange(for: Bool.self) { geometry in
            ConversationTranscriptScrollPolicy.isPastEnd(
                distanceToBottom: ConversationTranscriptScrollPolicy.distanceToBottom(
                    contentHeight: geometry.contentSize.height,
                    contentOffsetY: geometry.contentOffset.y,
                    containerHeight: geometry.visibleRect.height,
                    bottomInset: geometry.contentInsets.bottom
                ),
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.visibleRect.height,
                verticalInsets: geometry.contentInsets.top + geometry.contentInsets.bottom
            )
        } action: { _, isPastEnd in
            if isPastEnd {
                scheduleRePinIfRestingPastEnd(proxy: proxy)
            }
        }
        .onDisappear {
            cancelPastEndRePin()
            cancelDeferredContainerRePin()
            cancelBottomBandRePin()
            send(.viewDisappeared, proxy: proxy)
        }
    }

    /// The one transition of the follow / unrealized-end recovery lifecycle
    /// (see `ConversationTranscriptRecoveryLifecycle`): the next state is
    /// stored, then every effect is executed in order. `animated` is the
    /// animation of the `.scrollToEnd` the event issues and of the follow a
    /// `.startFollowTask` begins: a follow's own, none for a recovery's
    /// corrections. Returns the effects.
    @discardableResult
    private func send(_ event: Lifecycle.Event, proxy: ScrollViewProxy, animated: Bool = true) -> [Lifecycle.Effect] {
        let (state, effects) = Lifecycle.transition(lifecycle, event)
        scrollState.lifecycle = state
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
            isScrollingToBottom = false
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
            userIsScrolledAway = true
        case let .recordRecoveryOutcome(terminal, corrections):
            scrollState.unrealizedEndRecoveryCorrections = corrections
            recordUnrealizedEndRecoveryReport(outcome: terminal, cancelled: false)
        case .log(let message):
            AppLog.userInterface.debug(message)
        }
    }

    private func startFollowTask(_ token: Lifecycle.FollowToken, forced: Bool, animated: Bool, proxy: ScrollViewProxy) {
        if forced {
            isScrollingToBottom = true
            scrollState.lastForcedFollowOutcome = nil
            scrollState.lastForcedFollowCorrections = 0
        }
        scrollState.followTasks[token] = Task { @MainActor in
            await runFollow(token, forced: forced, animated: animated, proxy: proxy)
        }
    }

    private func cancelRecoveryTask(_ token: Lifecycle.RecoveryToken) {
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
    /// no new edge); each correction pages the live scroll view up a
    /// viewport so rows realize above, then follows back to the end, and
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
    private func runUnrealizedEndRecovery(_ token: Lifecycle.RecoveryToken, proxy: ScrollViewProxy) async {
        let deadline = ContinuousClock.now
            + .milliseconds(Constants.Conversation.Transcript.followLandingTimeoutMilliseconds)
        var correctionsLeft = Constants.Conversation.Transcript.followLandingRetries
        var previous: ScrollViewMomentumProxy.RestingGeometry?
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
                timedOut: ContinuousClock.now >= deadline
            )
            previous = geometry
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
                case .recover:
                    guard !effects.isEmpty else { continue }
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
    private func recordUnrealizedEndRecoveryReport(
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

    /// The last episode's report or, with one in flight (`recovering`) or
    /// none armed yet (`notAttempted`), the classifier's reading of the
    /// current state.
    private var unrealizedEndRecoveryDemoReport: ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport {
        scrollState.lastUnrealizedEndRecoveryReport
            ?? ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport(
                outcome: nil,
                corrections: scrollState.unrealizedEndRecoveryCorrections,
                episodes: scrollState.unrealizedEndRecoveryEpisodes,
                endRealized: lifecycle.isEndRealized,
                cancelled: false
            )
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
    private func scheduleRePinIfRestingPastEnd(
        proxy: ScrollViewProxy,
        confirming: ScrollViewMomentumProxy.RestingGeometry? = nil
    ) {
        scrollState.pastEndRePinTask?.cancel()
        scrollState.pastEndRePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled else { return }
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
    private var isFollowing: Bool {
        lifecycle.isFollowing || isScrollingToBottom
    }

    private func cancelPastEndRePin() {
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
    /// A pin issued is re-checked on settle too: a resize animated over
    /// several frames (the keyboard) pins on each of them against a lazy
    /// stack still re-estimating its rows, and could leave the viewport far
    /// from the bottom with the away edge consumed here (#276). Scrolled
    /// away, the content under the reader already stays put (the container
    /// resizes at its bottom edge). Returns false when the edge is to be
    /// applied as usual.
    private func rePinAfterContainerHeightChange(
        from oldContainerHeight: CGFloat,
        to newContainerHeight: CGFloat,
        proxy: ScrollViewProxy
    ) -> Bool {
        switch ConversationTranscriptScrollPolicy.containerHeightChangeDecision(
            oldContainerHeight: oldContainerHeight,
            newContainerHeight: newContainerHeight,
            isInteracting: scrollMomentumProxy.isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
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
        scrollState.containerRePinTask?.cancel()
        scrollState.containerRePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled else { return }
            scrollState.containerRePinTask = nil
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

    private func cancelDeferredContainerRePin() {
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
    private func scheduleBottomBandRePinIfNeeded(proxy: ScrollViewProxy) {
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
        scrollState.bottomBandRePinTask?.cancel()
        scrollState.bottomBandRePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled else { return }
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

    private func cancelBottomBandRePin() {
        scrollState.bottomBandRePinTask?.cancel()
        scrollState.bottomBandRePinTask = nil
    }

    /// Applies a geometry edge to `userIsScrolledAway` under the rule that
    /// only a gesture may break the pin (see
    /// `ConversationTranscriptScrollPolicy.scrolledAwayTransition`), and
    /// follows a pinned viewport that content grew under straight back to
    /// the bottom. The pin goes through SwiftUI's own layout, as the
    /// container re-pin does: the UIScrollView may not have laid out the new
    /// content yet when this runs. `isInteracting` defaults to the live
    /// gesture state; a phase ending passes true for its final sample. The
    /// takeover latch is released against the live state, so the phase
    /// ending pinned releases it at once. An at-bottom edge over an
    /// unrealized end row clears nothing (#338): the row realizing replays
    /// the live edge (see the marker's `onAppear`).
    private func applyScrolledAwayEdge(geometryAway: Bool, proxy: ScrollViewProxy) {
        applyScrolledAwayEdge(
            geometryAway: geometryAway,
            isInteracting: isUserInteracting,
            proxy: proxy
        )
    }

    private func applyScrolledAwayEdge(
        geometryAway: Bool,
        isInteracting: Bool,
        proxy: ScrollViewProxy
    ) {
        let next = ConversationTranscriptScrollPolicy.scrolledAwayTransition(
            current: userIsScrolledAway,
            geometryAway: geometryAway,
            isInteracting: isInteracting,
            isEndRealized: lifecycle.isEndRealized
        )
        if next != userIsScrolledAway {
            userIsScrolledAway = next
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
            proxy.scrollTo("scroll-bottom", anchor: .bottom)
        }
    }

    /// The one gesture predicate every scrolled-away and forced-follow
    /// decision reads: the UIScrollView flags once the finder resolved, or
    /// the SwiftUI scroll phase, which also covers a gesture on a transcript
    /// whose scroll view the finder has not resolved yet.
    private var isUserInteracting: Bool {
        scrollMomentumProxy.isInteracting || scrollState.isUserScrollPhase
    }

    /// Applies the live distance as a geometry edge (see
    /// `applyScrolledAwayEdge`), for the moments the geometry observer's
    /// edges were suppressed or may have been dropped: a follow draining, or
    /// the user taking over from a forced follow.
    private func applyLiveScrolledAwayEdge(proxy: ScrollViewProxy) {
        applyLiveScrolledAwayEdge(isInteracting: isUserInteracting, proxy: proxy)
    }

    private func applyLiveScrolledAwayEdge(isInteracting: Bool, proxy: ScrollViewProxy) {
        guard let distance = scrollMomentumProxy.distanceToBottom else { return }
        applyScrolledAwayEdge(
            geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: distance),
            isInteracting: isInteracting,
            proxy: proxy
        )
    }

    @ViewBuilder
    private func transcriptRows(proxy: ScrollViewProxy, dividerAnchorId: String?) -> some View {
        if viewModel.isTruncated {
            truncationBanner
                .id("truncation-banner")
        }

        ForEach(viewModel.filteredMessages) { message in
            messageRow(for: message)
                .id(message.id)
            if message.id == dividerAnchorId {
                NewMessagesDividerView()
                    .id("new-messages-divider")
            }
        }

        #if !os(visionOS)
        // On visionOS the composer renders these as large chips above the
        // field instead (MessageInputView).
        if !viewModel.suggestedPrompts.isEmpty, !viewModel.isStreaming {
            suggestedPromptsView
                .id("suggested-prompts")
        }
        #endif

        if viewModel.isStreaming {
            thinkingIndicatorView
                .transition(.move(edge: .top).combined(with: .opacity))
                .id("thinking-indicator")
        }

        // The stack's bottom padding lives on the marker so that
        // `scrollTo("scroll-bottom", anchor: .bottom)` targets the true end
        // of the content, not a point 12 points above it that a landing
        // judged against `followLandingTolerance` could never reach. Its
        // realization is the end-row signal the unrealized-end recovery
        // reads (#338): the lazy stack appears and disappears the marker as
        // it realizes and drops it. Realizing while scrolled away replays
        // the live edge; derealizing arms the recovery.
        if demoWithdrawnEnd == nil {
            Color.clear.frame(height: Layout.bottomAnchorHeight)
                .padding(.bottom, Layout.bottomAnchorPadding)
                .id("scroll-bottom")
                .onAppear {
                    send(.endRealized(userIsScrolledAway: userIsScrolledAway), proxy: proxy)
                }
                .onDisappear {
                    send(.endDerealized, proxy: proxy)
                }
        } else {
            // Demo-only stand-in while the marker is withdrawn (see
            // `withdrawEndRowForDemo`): the same height, so the content
            // height and every offset the recovery reads are unchanged, but
            // no id and no realization handlers — `scrollTo("scroll-bottom")`
            // finds nothing and `isEndRealized` stays false, exactly as over
            // a dropped end row.
            Color.clear.frame(height: Layout.bottomAnchorHeight)
                .padding(.bottom, Layout.bottomAnchorPadding)
        }
    }

    private func messageRow(for message: ConversationMessage) -> some View {
        MessageView(
            message: message,
            workspaceId: viewModel.workspaceId,
            onNavigateToNote: onNavigateToNote,
            onNavigateToAgent: onNavigateToAgent,
            hydratingBlockIds: viewModel.store.hydratingBlockIds(forMessage: message.id)
        ) { blockId in
            let messageId = message.id
            Task {
                await viewModel.store.hydrateBlock(
                    messageId: messageId,
                    blockId: blockId
                )
            }
        }
    }

    // MARK: - Demo-only controlled end derealization (#338)

    /// Nil outside `--demo-data` without reading the state, so production
    /// bodies take no dependency on it.
    private var demoWithdrawnEnd: ConversationTranscriptScrollState.DemoEndDerealization? {
        DemoMode.isEnabled ? scrollState.demoEndDerealization : nil
    }

    /// Withdraws the end row once the trigger file exists
    /// (`DemoFixtures.configuredEndDerealizationTriggerFile`): the marker leaves the
    /// lazy stack, its real `onDisappear` arms the recovery through the
    /// ordinary `.endDerealized` edge, and the recovery runs unchanged — nothing
    /// it reads is fabricated. Waits for the live scroll view so the offset
    /// the restore is judged against is the one the recovery pages from.
    private func withdrawEndRowForDemo() async {
        guard !scrollState.demoEndDerealizationTriggered else { return }
        while scrollMomentumProxy.restingGeometry == nil {
            try? await Task.sleep(for: DemoFixtures.triggerFilePollInterval)
            guard !Task.isCancelled else { return }
        }
        guard let geometry = scrollMomentumProxy.restingGeometry else { return }
        scrollState.demoEndDerealizationTriggered = true
        let mode = DemoFixtures.configuredEndDerealizationMode
        AppLog.userInterface.debug("[SCROLL] Demo: withdrawing the end row (\(mode.rawValue)) at \(geometry.contentOffsetY)")
        scrollState.demoEndDerealization = ConversationTranscriptScrollState.DemoEndDerealization(
            mode: mode,
            withdrawnOffsetY: geometry.contentOffsetY
        )
    }

    /// Puts the withdrawn end row back on evidence from the live scroll view
    /// alone (see `DemoFixtures.shouldRestoreDerealizedEnd`): the recovery's
    /// page up in `release` mode, or a gesture in either. Restored at the
    /// end of the content while the viewport rests above it, the marker is
    /// unrealized until the recovery's own follow back reaches it, so its
    /// real `onAppear` is what resolves the episode.
    private func restoreDerealizedEndIfMoved() {
        guard let withdrawn = demoWithdrawnEnd,
              let geometry = scrollMomentumProxy.restingGeometry,
              DemoFixtures.shouldRestoreDerealizedEnd(
                mode: withdrawn.mode,
                withdrawnOffsetY: withdrawn.withdrawnOffsetY,
                contentOffsetY: geometry.contentOffsetY,
                containerHeight: geometry.containerHeight,
                isInteracting: isUserInteracting
              )
        else { return }
        AppLog.userInterface.debug("[SCROLL] Demo: restoring the end row at \(geometry.contentOffsetY)")
        scrollState.demoEndDerealization = nil
    }

    private func goToEndButton(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollMomentumProxy.stopMomentum()
            claimViewportForExplicitFollow(proxy: proxy)
            isScrollingToBottom = true
            scrollState.goToEndRequested = true
            userIsScrolledAway = false
        } label: {
            HStack(spacing: Layout.goToEndSpacing) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                Text("Go to End")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, Layout.goToEndHorizontalPadding)
            .padding(.vertical, Layout.goToEndVerticalPadding)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(
                color: .black.opacity(Layout.goToEndShadowOpacity),
                radius: Layout.goToEndShadowRadius,
                y: Layout.goToEndShadowYOffset
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcript.goToEnd")
        .padding(.bottom, Layout.goToEndBottomPadding)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(
            .easeInOut(duration: Constants.Conversation.Transcript.goToEndVisibilityAnimationDuration),
            value: userIsScrolledAway
        )
    }

    private var thinkingIndicatorView: some View {
        HStack(spacing: Layout.thinkingIndicatorSpacing) {
            ProgressView()
                .scaleEffect(Layout.thinkingIndicatorScale)
                .frame(width: Layout.thinkingIndicatorSide, height: Layout.thinkingIndicatorSide)
            Text("Thinking...")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.horizontal, Layout.thinkingIndicatorHorizontalPadding)
        .padding(.vertical, Layout.thinkingIndicatorVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if !os(visionOS)
    private var suggestedPromptsView: some View {
        VStack(spacing: Layout.suggestedPromptSpacing) {
            ForEach(Array(viewModel.suggestedPrompts.enumerated()), id: \.element) { index, prompt in
                Button {
                    Task { await viewModel.sendSuggestedPrompt(prompt) }
                } label: {
                    HStack(spacing: Layout.suggestedPromptSpacing) {
                        Image(systemName: "paperplane")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Layout.suggestedPromptHorizontalPadding)
                    .padding(.vertical, Layout.suggestedPromptVerticalPadding)
                    .background(Theme.muted(for: colorScheme).opacity(Layout.suggestedPromptBackgroundOpacity))
                    .clipShape(RoundedRectangle(cornerRadius: Layout.suggestedPromptCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.suggestedPromptCornerRadius)
                            .strokeBorder(
                                Theme.border(for: colorScheme).opacity(Layout.suggestedPromptBorderOpacity),
                                lineWidth: Layout.suggestedPromptBorderWidth
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcript.suggestedPrompt.\(index)")
            }
        }
    }
    #endif

    private var truncationBanner: some View {
        HStack(spacing: Layout.truncationBannerSpacing) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text("Showing the most recent \(viewModel.filteredMessages.count) of \(viewModel.totalMessageCount) messages.\nSee the full conversation on the desktop app.")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Layout.truncationBannerHorizontalPadding)
        .padding(.vertical, Layout.truncationBannerVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(Theme.muted(for: colorScheme).opacity(Layout.truncationBannerBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.truncationBannerCornerRadius))
    }

    /// Runs exactly once per transcript lifetime from whichever loading trigger
    /// fires first, after LazyVStack has had time to finish layout.
    private func runInitialScrollIfNeeded(proxy: ScrollViewProxy) {
        guard !initialScrollScheduled else { return }
        initialScrollScheduled = true
        let generation = scrollState.initialScrollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.initialScrollDelay) {
            performInitialScrollWhenReady(
                proxy: proxy,
                scrollViewWaitElapsed: false,
                generation: generation
            )
        }
    }

    /// The finder resolving is the signal the transcript is hosted; an entry
    /// scroll issued while waiting for it is picked up here. Hosting precedes
    /// LazyVStack's first layout pass, so the resolved path gets the same
    /// `initialScrollDelay` the loading triggers get before it scrolls.
    private func handleScrollViewResolved(proxy: ScrollViewProxy) {
        let generation = scrollState.initialScrollGeneration
        guard scrollState.initialScrollAwaitingScrollView else {
            // Defensive: onAppear / isLoading already schedule the entry
            // scroll, so this only matters if the edge ever precedes both.
            if !viewModel.isLoading {
                runInitialScrollIfNeeded(proxy: proxy)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.initialScrollDelay) {
            performInitialScrollWhenReady(
                proxy: proxy,
                scrollViewWaitElapsed: false,
                generation: generation
            )
        }
    }

    /// A `scrollTo` issued before the UIScrollView is hosted is lost and the
    /// bottom anchor wins, so when the entry timer beats hosting (instant load
    /// during the push transition) the scroll waits for the finder's edge —
    /// bounded by `initialScrollHostingTimeout` so a finder that never
    /// resolves still scrolls. Performs at most once across all paths.
    private func performInitialScrollWhenReady(
        proxy: ScrollViewProxy,
        scrollViewWaitElapsed: Bool,
        generation: Int
    ) {
        guard generation == scrollState.initialScrollGeneration else { return }
        switch ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: scrollState.initialScrollPerformed,
            scrollViewResolved: scrollMomentumProxy.hasResolvedScrollView,
            scrollViewWaitElapsed: scrollViewWaitElapsed
        ) {
        case .skip:
            return
        case .waitForScrollView:
            scrollState.initialScrollAwaitingScrollView = true
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.Conversation.Transcript.initialScrollHostingTimeout
            ) {
                performInitialScrollWhenReady(
                    proxy: proxy,
                    scrollViewWaitElapsed: true,
                    generation: generation
                )
            }
        case .perform:
            scrollState.initialScrollPerformed = true
            scrollState.initialScrollAwaitingScrollView = false
            performInitialScroll(proxy: proxy, generation: generation)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.Conversation.Transcript.initialScrollSettleDelay
            ) {
                guard generation == scrollState.initialScrollGeneration else { return }
                hasInitiallyScrolled = true
            }
        }
    }

    /// Without an unread divider the entry scroll is a forced follow, so its
    /// landing is verified from the live geometry like any other.
    private func performInitialScroll(proxy: ScrollViewProxy, generation: Int) {
        guard viewModel.newMessagesDividerAnchorId != nil else {
            scrollToBottom(proxy: proxy, forced: true, animated: false)
            return
        }
        proxy.scrollTo("new-messages-divider", anchor: .top)
        // Runs before `hasInitiallyScrolled` flips (probe < settle delay), so
        // no automatic follow can be queued ahead of this decision.
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.dividerProbeDelay) {
            scrollState.applyDividerProbe(
                distanceToBottom: scrollMomentumProxy.distanceToBottom,
                generation: generation
            )
        }
    }

    private func followStreamingDeltaIfDrifted(proxy: ScrollViewProxy) {
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
    private func takeOverPendingFollowIfGesture(proxy: ScrollViewProxy) {
        takeOverPendingFollowIfGesture(isInteracting: isUserInteracting, proxy: proxy)
    }

    private func takeOverPendingFollowIfGesture(isInteracting: Bool, proxy: ScrollViewProxy) {
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
    private func cancelPendingFollowOnTakeover(proxy: ScrollViewProxy) {
        if case .follow(_, forced: true) = lifecycle.owner {
            scrollState.forcedFollowTakenOverByGesture = true
        }
        isScrollingToBottom = false
        send(.followCancelledByGesture, proxy: proxy)
    }

    /// An explicit request — Go to End, or the user's own message — takes
    /// the viewport back from any gesture: the takeover latch is released
    /// and the SwiftUI phase is no longer the gesture's, so a phase ending
    /// delivered after the request (the fling it stopped, the tap that sent
    /// the message lifting) is not applied as the gesture's final sample and
    /// does not take the request's follow over. An unrealized-end recovery
    /// in flight is cancelled too: the request's follow owns the viewport.
    private func claimViewportForExplicitFollow(proxy: ScrollViewProxy) {
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
    private func scrollToBottom(proxy: ScrollViewProxy, forced: Bool, animated: Bool = true) {
        if forced, !ConversationTranscriptScrollPolicy.shouldHonorForcedFollow(
            takenOverByGesture: scrollState.forcedFollowTakenOverByGesture
        ) {
            AppLog.userInterface.debug("[SCROLL] Forced follow refused: a gesture took over the last one")
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
        isScrollingToBottom = false
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
        if animated {
            withAnimation(.easeOut(duration: Constants.Conversation.Transcript.scrollAnimationDuration)) {
                proxy.scrollTo("scroll-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("scroll-bottom", anchor: .bottom)
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

extension ConversationTranscriptScrollState {
    func applyDividerProbe(distanceToBottom: CGFloat?, generation: Int) {
        guard generation == initialScrollGeneration else { return }
        if NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: distanceToBottom) {
            userIsScrolledAway = true
        }
    }
}

private extension View {
    /// Under `--demo-data` only: exposes `value` as the view's accessibility
    /// value so the XCUITests can read the transcript's landing outcome.
    /// Zero-impact otherwise — the value is neither computed (so the observed
    /// state behind it is not a body dependency) nor applied.
    @ViewBuilder
    func demoAccessibilityValue(_ value: @autoclosure () -> String) -> some View {
        if DemoMode.isEnabled {
            accessibilityValue(value())
        } else {
            self
        }
    }

    /// Under `--demo-data` with `--demo-end-derealization-trigger-file` only:
    /// polls for the trigger file and calls `onTrigger` once it exists, and
    /// calls `onGeometryChange` on every content offset change so the
    /// withdrawn end row can be restored on live evidence (#338). Neither
    /// the task nor the observer is installed otherwise.
    @ViewBuilder
    func demoEndDerealization(
        triggerFile: URL?,
        onTrigger: @escaping @MainActor () async -> Void,
        onGeometryChange: @escaping @MainActor () -> Void
    ) -> some View {
        if DemoMode.isEnabled, let triggerFile {
            self
                .task {
                    guard (try? await DemoFixtures.wait(for: .triggerFile(triggerFile))) != nil else { return }
                    await onTrigger()
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, _ in
                    onGeometryChange()
                }
        } else {
            self
        }
    }
}

private extension ScrollPhase {
    /// Phases driven by the user's finger or the deceleration after it;
    /// `.animating` is a programmatic scroll and `.idle` is at rest.
    var isUserDriven: Bool {
        self == .tracking || self == .interacting || self == .decelerating
    }
}
