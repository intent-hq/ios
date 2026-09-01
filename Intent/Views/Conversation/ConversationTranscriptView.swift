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
    private func transcriptScrollView(
        proxy: ScrollViewProxy,
        dividerAnchorId: String?
    ) -> some View {
        transcriptScrollBase(dividerAnchorId: dividerAnchorId)
            .onChange(of: viewModel.filteredMessages.count) { oldCount, newCount in
                if newCount > oldCount,
                   let lastMessage = viewModel.filteredMessages.last,
                   lastMessage.role == .user {
                    userIsScrolledAway = false
                }
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.isStreaming) { _, _ in
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.store.streamingUpdateCount) { _, _ in
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.queuedMessages.count) { _, _ in
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.store.isWaitingForAgents) { _, _ in
                if shouldFollowToBottom {
                    scrollToBottom(proxy: proxy)
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
                if !scrolledAway {
                    scrollToBottom(proxy: proxy)
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
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .flippedUpsideDown()
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        // Keyboard dismissal is installed by ScrollViewFinder. A SwiftUI tap
        // gesture here would starve Textual's UIKit link-tap recognizer.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let isScrolledAway = ConversationTranscriptScrollPolicy.isScrolledAway(
                flippedContentOffsetY: geometry.contentOffset.y
            )
            AppLog.ui.debug("[SCROLL] contentOffset.y=\(geometry.contentOffset.y), contentSize=\(geometry.contentSize.height), containerSize=\(geometry.containerSize.height), atBottom=\(!isScrolledAway)")
            return isScrolledAway
        } action: { _, isScrolledAway in
            AppLog.ui.debug("[SCROLL] isScrolledAway=\(isScrolledAway), hasInitiallyScrolled=\(hasInitiallyScrolled), isScrollingToBottom=\(isScrollingToBottom)")
            if hasInitiallyScrolled && !isScrollingToBottom {
                userIsScrolledAway = isScrolledAway
            }
        }
    }

    @ViewBuilder
    private func transcriptRows(dividerAnchorId: String?) -> some View {
        Color.clear.frame(height: 8)
            .flippedUpsideDown()
            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
            .id("scroll-bottom")

        if viewModel.isStreaming {
            thinkingIndicatorView
                .transition(.move(edge: .top).combined(with: .opacity))
                .flippedUpsideDown()
                .id("thinking-indicator")
        }

        if !viewModel.suggestedPrompts.isEmpty && !viewModel.isStreaming {
            suggestedPromptsView
                .flippedUpsideDown()
                .id("suggested-prompts")
        }

        // Newest-first code order appears bottom-to-top in the flipped list.
        ForEach(viewModel.filteredMessages.reversed()) { message in
            if message.id == dividerAnchorId {
                NewMessagesDividerView()
                    .flippedUpsideDown()
                    .id("new-messages-divider")
            }
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
            .flippedUpsideDown()
            .id(message.id)
        }

        if viewModel.isTruncated {
            truncationBanner
                .flippedUpsideDown()
                .id("truncation-banner")
        }
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
        .animation(.easeInOut(duration: 0.2), value: userIsScrolledAway)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            performInitialScroll(proxy: proxy)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                hasInitiallyScrolled = true
            }
        }
    }

    private func performInitialScroll(proxy: ScrollViewProxy) {
        guard viewModel.newMessagesDividerAnchorId != nil else {
            scrollToBottom(proxy: proxy, animated: false)
            return
        }
        proxy.scrollTo("new-messages-divider", anchor: .bottom)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let offsetY = scrollMomentumProxy.scrollView?.contentOffset.y ?? 0
            if NewMessagesDivider.followDisabledAfterEntryScroll(
                flippedContentOffsetY: offsetY
            ) {
                userIsScrolledAway = true
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        scrollDebounceTask?.cancel()
        scrollDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("scroll-bottom", anchor: .top)
                }
            } else {
                proxy.scrollTo("scroll-bottom", anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isScrollingToBottom = false
        }
    }
}