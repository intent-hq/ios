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
    /// and at most re-pin a drifted viewport (see the policy).
    private func transcriptScrollView(
        proxy: ScrollViewProxy,
        dividerAnchorId: String?
    ) -> some View {
        transcriptScrollBase(dividerAnchorId: dividerAnchorId)
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
            .onChange(of: viewModel.queuedMessages.count) { _, _ in
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy, forced: false)
                }
            }
            .onChange(of: viewModel.store.isWaitingForAgents) { _, _ in
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy, forced: false)
                }
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
            .onChange(of: userIsScrolledAway) { _, scrolledAway in
                if scrolledAway {
                    cancelPendingAutomaticFollow()
                } else {
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

    private func transcriptScrollBase(dividerAnchorId: String?) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                transcriptRows(dividerAnchorId: dividerAnchorId)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        // Keyboard dismissal is installed by ScrollViewFinder. A SwiftUI tap
        // gesture here would starve Textual's UIKit link-tap recognizer.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: ConversationTranscriptScrollPolicy.distanceToBottom(
                    contentHeight: geometry.contentSize.height,
                    contentOffsetY: geometry.contentOffset.y,
                    containerHeight: geometry.containerSize.height,
                    bottomInset: geometry.contentInsets.bottom
                )
            )
        } action: { _, isScrolledAway in
            if hasInitiallyScrolled && !isScrollingToBottom {
                userIsScrolledAway = isScrolledAway
            }
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
            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
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
            performInitialScroll(proxy: proxy)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.Conversation.Transcript.initialScrollSettleDelay
            ) {
                hasInitiallyScrolled = true
            }
        }
    }

    private func performInitialScroll(proxy: ScrollViewProxy) {
        guard viewModel.newMessagesDividerAnchorId != nil else {
            scrollToBottom(proxy: proxy, animated: false, forced: true)
            return
        }
        proxy.scrollTo("new-messages-divider", anchor: .top)
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.dividerProbeDelay) {
            let distanceToBottom = scrollMomentumProxy.distanceToBottom ?? 0
            if NewMessagesDivider.followDisabledAfterEntryScroll(
                distanceToBottom: distanceToBottom
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
                if animated {
                    withAnimation(.easeOut(duration: Constants.Conversation.Transcript.scrollAnimationDuration)) {
                        proxy.scrollTo("scroll-bottom", anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo("scroll-bottom", anchor: .bottom)
                }
                try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.scrollCompletionMilliseconds))
                guard !Task.isCancelled else { return }
            }
            isScrollingToBottom = false
            scrollState.pendingFollowIsForced = false
        }
    }
}