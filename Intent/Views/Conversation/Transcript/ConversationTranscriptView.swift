import SwiftUI

struct ConversationTranscriptView: View {
    let viewModel: ConversationViewModel
    let scrollState: ConversationTranscriptScrollState
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let transcriptRowSpacing: CGFloat = 16
        static let transcriptHorizontalPadding: CGFloat = 16
        static let transcriptTopPadding: CGFloat = 12
        static let transcriptBottomPadding: CGFloat = 24
        static let bottomAnchorHeight: CGFloat = 8
        static let goToEndSpacing: CGFloat = 4
        static let goToEndHorizontalPadding: CGFloat = 14
        static let goToEndVerticalPadding: CGFloat = 8
        static let goToEndShadowOpacity: Double = 0.15
        static let goToEndShadowRadius: CGFloat = 4
        static let goToEndShadowYOffset: CGFloat = 2
        static let goToEndBottomPadding: CGFloat = 8
        static let thinkingIndicatorSpacing: CGFloat = 6
        static let thinkingIndicatorScale: CGFloat = 0.7
        static let thinkingIndicatorSide: CGFloat = 16
        static let thinkingIndicatorHorizontalPadding: CGFloat = 12
        static let thinkingIndicatorVerticalPadding: CGFloat = 4
        static let suggestedPromptSpacing: CGFloat = 8
        static let suggestedPromptContentSpacing: CGFloat = 8
        static let suggestedPromptHorizontalPadding: CGFloat = 14
        static let suggestedPromptVerticalPadding: CGFloat = 10
        static let suggestedPromptBackgroundOpacity: Double = 0.4
        static let suggestedPromptCornerRadius: CGFloat = 10
        static let suggestedPromptBorderOpacity: Double = 0.3
        static let truncationBannerSpacing: CGFloat = 8
        static let truncationBannerHorizontalPadding: CGFloat = 16
        static let truncationBannerVerticalPadding: CGFloat = 12
        static let truncationBannerCornerRadius: CGFloat = 10
    }

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
}

private extension ConversationTranscriptView {
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
            LazyVStack(spacing: Layout.transcriptRowSpacing) {
                transcriptRows(dividerAnchorId: dividerAnchorId)
            }
            .padding(.horizontal, Layout.transcriptHorizontalPadding)
            .padding(.top, Layout.transcriptTopPadding)
            .padding(.bottom, Layout.transcriptBottomPadding)
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
            AppLog.userInterface.debug("[SCROLL] contentOffset.y=\(geometry.contentOffset.y), contentSize=\(geometry.contentSize.height), containerSize=\(geometry.containerSize.height), atBottom=\(!isScrolledAway)")
            return isScrolledAway
        } action: { _, isScrolledAway in
            AppLog.userInterface.debug("[SCROLL] isScrolledAway=\(isScrolledAway), hasInitiallyScrolled=\(hasInitiallyScrolled), isScrollingToBottom=\(isScrollingToBottom)")
            if hasInitiallyScrolled, !isScrollingToBottom {
                userIsScrolledAway = isScrolledAway
            }
        }
    }

    @ViewBuilder
    private func transcriptRows(dividerAnchorId: String?) -> some View {
        Color.clear.frame(height: Layout.bottomAnchorHeight)
            .flippedUpsideDown()
            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
            .id("scroll-bottom")

        if viewModel.isStreaming {
            thinkingIndicatorView
                .transition(.move(edge: .top).combined(with: .opacity))
                .flippedUpsideDown()
                .id("thinking-indicator")
        }

        #if !os(visionOS)
        // On visionOS the composer renders these as large chips above the
        // field instead (MessageInputView).
        if !viewModel.suggestedPrompts.isEmpty, !viewModel.isStreaming {
            suggestedPromptsView
                .flippedUpsideDown()
                .id("suggested-prompts")
        }
        #endif

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
            .flippedUpsideDown()
            .id(message.id)
        }

        if viewModel.isTruncated {
            truncationBanner
                .flippedUpsideDown()
                .id("truncation-banner")
        }
    }
}

private extension ConversationTranscriptView {
    private var goToEndButton: some View {
        Button {
            scrollMomentumProxy.stopMomentum()
            isScrollingToBottom = true
            userIsScrolledAway = false
        } label: {
            HStack(spacing: Layout.goToEndSpacing) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
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
            ForEach(viewModel.suggestedPrompts, id: \.self) { prompt in
                Button {
                    Task { await viewModel.sendSuggestedPrompt(prompt) }
                } label: {
                    HStack(spacing: Layout.suggestedPromptContentSpacing) {
                        Image(systemName: "paperplane")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .accessibilityHidden(true)
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
        HStack(spacing: Layout.truncationBannerSpacing) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
            Text("Showing the most recent \(viewModel.filteredMessages.count) of \(viewModel.totalMessageCount) messages.\nSee the full conversation on the desktop app.")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Layout.truncationBannerHorizontalPadding)
        .padding(.vertical, Layout.truncationBannerVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(Theme.muted(for: colorScheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Layout.truncationBannerCornerRadius))
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
            scrollToBottom(proxy: proxy, animated: false)
            return
        }
        proxy.scrollTo("new-messages-divider", anchor: .bottom)
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.dividerProbeDelay) {
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
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.scrollDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: Constants.Conversation.Transcript.scrollAnimationDuration)) {
                    proxy.scrollTo("scroll-bottom", anchor: .top)
                }
            } else {
                proxy.scrollTo("scroll-bottom", anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(Constants.Conversation.Transcript.scrollCompletionMilliseconds))
            guard !Task.isCancelled else { return }
            isScrollingToBottom = false
        }
    }
}
