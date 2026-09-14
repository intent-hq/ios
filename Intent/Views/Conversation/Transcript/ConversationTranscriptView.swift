import SwiftUI

struct ConversationTranscriptView: View {
    let viewModel: ConversationViewModel
    let scrollState: ConversationTranscriptScrollState
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var scrollMomentumProxy: ScrollViewMomentumProxy {
        scrollState.momentumProxy
    }

    private var scrollDebounceTask: Task<Void, Never>? {
        get { scrollState.debounceTask }
        nonmutating set { scrollState.debounceTask = newValue }
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
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                transcriptScrollView(proxy: proxy, dividerAnchorId: dividerAnchorId)
            }

            if userIsScrolledAway {
                goToEndButton
            }
        }
    }

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
                let appendedUserMessage = newCount > oldCount
                    && viewModel.filteredMessages.last?.role == .user
                if appendedUserMessage {
                    userIsScrolledAway = false
                }
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy, forced: appendedUserMessage)
                }
            }
            .onChange(of: viewModel.isStreaming) { _, isStreaming in
                if ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
                    isStreaming: isStreaming,
                    hasInitiallyScrolled: hasInitiallyScrolled,
                    userIsScrolledAway: userIsScrolledAway
                ) {
                    scrollToBottom(proxy: proxy, forced: true)
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
                if scrolledAway {
                    cancelPendingAutomaticFollow()
                } else if ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
                    isScrollingToBottom: isScrollingToBottom
                ) {
                    scrollToBottom(proxy: proxy, forced: true)
                }
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

    private func transcriptScrollBase(proxy: ScrollViewProxy, dividerAnchorId: String?) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                transcriptRows(dividerAnchorId: dividerAnchorId)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 12)
            // Hosted on the stack itself, not a lazily realized row, so the
            // UIScrollView is found regardless of which rows exist.
            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
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
            scrollState.liveIsScrolledAway = new.isScrolledAway
            if rePinAfterContainerHeightChange(
                from: old.containerHeight, to: new.containerHeight, proxy: proxy
            ) { return }
            syncScrolledAwayFromGeometry()
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
                scheduleRePinIfRestingPastEnd()
            }
        }
        .onDisappear(perform: cancelPastEndRePin)
    }

    /// Re-checks the live scroll view once the geometry has had time to
    /// settle (a bounce or a mid-animation frame reads past the end too) and
    /// clamps the offset back to the bottom once two checks agree; a viewport
    /// still bouncing or re-laying out is checked again after it settles,
    /// since the past-end edge has already fired and will not fire twice. A
    /// programmatic follow in flight is deferred the same way so the clamp
    /// cannot land mid-animation. Without a scroll view to clamp, the viewport
    /// is recorded as scrolled away through the usual gate so Go to End
    /// offers the way back once the gate is open.
    private func scheduleRePinIfRestingPastEnd(
        confirming: ScrollViewMomentumProxy.RestingGeometry? = nil
    ) {
        scrollState.pastEndRePinTask?.cancel()
        scrollState.pastEndRePinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.pastEndSettleMilliseconds))
            guard !Task.isCancelled else { return }
            scrollState.pastEndRePinTask = nil
            let outcome = scrollMomentumProxy.rePinIfRestingPastEnd(
                confirming: confirming,
                isFollowing: scrollDebounceTask != nil || isScrollingToBottom
            )
            switch outcome {
            case .deferred(let geometry):
                scheduleRePinIfRestingPastEnd(confirming: geometry)
            case .unavailable:
                scrollState.liveIsScrolledAway = true
                syncScrolledAwayFromGeometry()
            case .rePinned, .notPastEnd:
                break
            }
        }
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
    /// at the old bottom. Scrolled away, the content under the reader already
    /// stays put (the container resizes at its bottom edge). Returns false
    /// when the edge is to be applied as usual.
    private func rePinAfterContainerHeightChange(
        from oldContainerHeight: CGFloat,
        to newContainerHeight: CGFloat,
        proxy: ScrollViewProxy
    ) -> Bool {
        guard ConversationTranscriptScrollPolicy.shouldRePinOnContainerHeightChange(
            oldContainerHeight: oldContainerHeight,
            newContainerHeight: newContainerHeight,
            isInteracting: scrollMomentumProxy.isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        ) else { return false }
        proxy.scrollTo("scroll-bottom", anchor: .bottom)
        if scrollDebounceTask != nil {
            scrollToBottom(proxy: proxy, forced: scrollState.pendingFollowIsForced)
        }
        return true
    }

    /// Applies the latest geometry edge to `userIsScrolledAway` when the gate
    /// is open; called on every edge and again whenever the gate opens.
    private func syncScrolledAwayFromGeometry() {
        let resolved = ConversationTranscriptScrollPolicy.resolvedScrolledAway(
            live: scrollState.liveIsScrolledAway,
            current: userIsScrolledAway,
            hasInitiallyScrolled: hasInitiallyScrolled,
            isScrollingToBottom: isScrollingToBottom
        )
        if resolved != userIsScrolledAway {
            userIsScrolledAway = resolved
        }
    }

    @ViewBuilder
    private func transcriptRows(dividerAnchorId: String?) -> some View {
        if viewModel.isTruncated {
            truncationBanner
                .id("truncation-banner")
        }

        ForEach(viewModel.filteredMessages) { message in
            MessageView(
                message: message,
                workspaceId: viewModel.workspaceId,
                onNavigateToNote: onNavigateToNote,
                onNavigateToAgent: onNavigateToAgent,
                hydratingBlockIds: viewModel.store.hydratingBlockIds(forMessage: message.id),
                onHydrateBlock: { blockId in
                    let messageId = message.id
                    Task {
                        await viewModel.store.hydrateBlock(
                            messageId: messageId,
                            blockId: blockId
                        )
                    }
                }
            )
            .id(message.id)
            if message.id == dividerAnchorId {
                NewMessagesDividerView()
                    .id("new-messages-divider")
            }
        }

        #if !os(visionOS)
        // On visionOS the composer renders these as large chips above the
        // field instead (MessageInputView).
        if !viewModel.suggestedPrompts.isEmpty && !viewModel.isStreaming {
            suggestedPromptsView
                .id("suggested-prompts")
        }
        #endif

        if viewModel.isStreaming {
            thinkingIndicatorView
                .transition(.move(edge: .top).combined(with: .opacity))
                .id("thinking-indicator")
        }

        Color.clear.frame(height: 8)
            .id("scroll-bottom")
    }

    private var goToEndButton: some View {
        Button {
            scrollMomentumProxy.stopMomentum()
            isScrollingToBottom = true
            userIsScrolledAway = false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                Text("Go to End")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcript.goToEnd")
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(
            .easeInOut(duration: Constants.Conversation.Transcript.goToEndVisibilityAnimationDuration),
            value: userIsScrolledAway)
    }

    private var thinkingIndicatorView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
            Text("Thinking...")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if !os(visionOS)
    private var suggestedPromptsView: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.suggestedPrompts, id: \.self) { prompt in
                Button {
                    Task { await viewModel.sendSuggestedPrompt(prompt) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.muted(for: colorScheme).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                Theme.border(for: colorScheme).opacity(0.3),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
    #endif

    private var truncationBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text("Showing the most recent \(viewModel.filteredMessages.count) of \(viewModel.totalMessageCount) messages.\nSee the full conversation on the desktop app.")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.muted(for: colorScheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Runs exactly once per transcript lifetime from whichever loading trigger
    /// fires first, after LazyVStack has had time to finish layout.
    private func runInitialScrollIfNeeded(proxy: ScrollViewProxy) {
        guard !initialScrollScheduled else { return }
        initialScrollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.initialScrollDelay) {
            performInitialScrollWhenReady(proxy: proxy, scrollViewWaitElapsed: false)
        }
    }

    /// The finder resolving is the signal the transcript is hosted; an entry
    /// scroll issued while waiting for it is picked up here. Hosting precedes
    /// LazyVStack's first layout pass, so the resolved path gets the same
    /// `initialScrollDelay` the loading triggers get before it scrolls.
    private func handleScrollViewResolved(proxy: ScrollViewProxy) {
        guard scrollState.initialScrollAwaitingScrollView else {
            // Defensive: onAppear / isLoading already schedule the entry
            // scroll, so this only matters if the edge ever precedes both.
            if !viewModel.isLoading {
                runInitialScrollIfNeeded(proxy: proxy)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.initialScrollDelay) {
            performInitialScrollWhenReady(proxy: proxy, scrollViewWaitElapsed: false)
        }
    }

    /// A `scrollTo` issued before the UIScrollView is hosted is lost and the
    /// bottom anchor wins, so when the entry timer beats hosting (instant load
    /// during the push transition) the scroll waits for the finder's edge —
    /// bounded by `initialScrollHostingTimeout` so a finder that never
    /// resolves still scrolls. Performs at most once across all paths.
    private func performInitialScrollWhenReady(proxy: ScrollViewProxy, scrollViewWaitElapsed: Bool) {
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
                performInitialScrollWhenReady(proxy: proxy, scrollViewWaitElapsed: true)
            }
        case .perform:
            scrollState.initialScrollPerformed = true
            scrollState.initialScrollAwaitingScrollView = false
            performInitialScroll(proxy: proxy)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.Conversation.Transcript.initialScrollSettleDelay
            ) {
                hasInitiallyScrolled = true
                syncScrolledAwayFromGeometry()
            }
        }
    }

    private func performInitialScroll(proxy: ScrollViewProxy) {
        // A geometry edge recorded before this scroll (the initial layout at
        // the bottom) describes the pre-scroll viewport; dropping it keeps
        // the gate-open sync from overwriting the divider probe's flag.
        scrollState.liveIsScrolledAway = nil
        guard viewModel.newMessagesDividerAnchorId != nil else {
            scrollToBottom(proxy: proxy, animated: false, forced: true)
            return
        }
        proxy.scrollTo("new-messages-divider", anchor: .top)
        // Runs before `hasInitiallyScrolled` flips (probe < settle delay), so
        // no automatic follow can be queued ahead of this decision.
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.dividerProbeDelay) {
            if NewMessagesDivider.followDisabledAfterEntryScroll(
                distanceToBottom: scrollMomentumProxy.distanceToBottom
            ) {
                userIsScrolledAway = true
            }
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

    /// The user scrolling away drops an automatic follow still in its debounce;
    /// a forced one (Go to End sets `isScrollingToBottom`, so geometry cannot
    /// flip this flag during it anyway) keeps going.
    private func cancelPendingAutomaticFollow() {
        guard !scrollState.pendingFollowIsForced else { return }
        scrollDebounceTask?.cancel()
        scrollDebounceTask = nil
    }

    /// Stamps the request time up front so deltas arriving inside the debounce
    /// window are rejected by the policy instead of restarting the debounce.
    /// Forced follows always land and are never preempted by automatic ones;
    /// automatic follows are re-validated by the policy once the debounce
    /// elapses, so a user who scrolled away meanwhile is not snapped back.
    /// A forced follow that came to rest short of the bottom (rows realized
    /// during the animation grew the content under it) is issued again before
    /// the gate reopens, so the geometry it reopens on is the real bottom
    /// (see `ConversationTranscriptScrollPolicy.shouldRetryFollowLanding`).
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true, forced: Bool) {
        scrollState.lastFollowToBottomAt = ProcessInfo.processInfo.systemUptime
        if !forced && scrollState.pendingFollowIsForced { return }
        scrollDebounceTask?.cancel()
        scrollState.pendingFollowIsForced = forced
        scrollDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.scrollDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            let shouldExecute = ConversationTranscriptScrollPolicy.shouldExecuteFollow(
                forced: forced,
                userIsScrolledAway: userIsScrolledAway,
                distanceToBottom: scrollMomentumProxy.distanceToBottom
            )
            if shouldExecute {
                var retriesLeft = Constants.Conversation.Transcript.followLandingRetries
                while true {
                    if animated {
                        withAnimation(.easeOut(duration: Constants.Conversation.Transcript.scrollAnimationDuration)) {
                            proxy.scrollTo("scroll-bottom", anchor: .bottom)
                        }
                    } else {
                        proxy.scrollTo("scroll-bottom", anchor: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.scrollCompletionMilliseconds))
                    guard !Task.isCancelled else { return }
                    guard ConversationTranscriptScrollPolicy.shouldRetryFollowLanding(
                        forced: forced,
                        distanceToBottom: scrollMomentumProxy.distanceToBottom,
                        isInteracting: scrollMomentumProxy.isDragging,
                        retriesLeft: retriesLeft
                    ) else { break }
                    retriesLeft -= 1
                    AppLog.ui.debug("[SCROLL] Forced follow landed short of the bottom, scrolling again")
                }
            }
            isScrollingToBottom = false
            scrollState.pendingFollowIsForced = false
            scrollDebounceTask = nil
            syncScrolledAwayFromGeometry()
        }
    }
}