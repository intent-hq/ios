import SwiftUI

// These builders remain on the transcript so extraction does not add a new
// observation boundary or change the lazy stack's row and anchor identities.
extension ConversationTranscriptView {
    @ViewBuilder
    func transcriptRows(proxy: ScrollViewProxy, dividerAnchorId: String?) -> some View {
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
        let hydratingBlockIds = viewModel.store.hydratingBlockIds(forMessage: message.id)
        let cachedHeight = scrollState.rowHeightCache.height(
            for: message,
            hydratingBlockIds: hydratingBlockIds
        )
        return MessageView(
            message: message,
            workspaceId: viewModel.workspaceId,
            onNavigateToNote: onNavigateToNote,
            onNavigateToAgent: onNavigateToAgent,
            hydratingBlockIds: hydratingBlockIds,
            onLayoutChange: {
                scrollState.rowHeightCache.invalidate(messageId: message.id)
            },
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
        .modifier(
            ConversationTranscriptRowHeightFrame(
                cachedHeight: cachedHeight,
                isStreaming: message.isStreaming
            ) { height in
                scrollState.rowHeightCache.record(
                    height: height,
                    for: message,
                    hydratingBlockIds: hydratingBlockIds,
                    retainingMessagesWithIDs: Set(viewModel.filteredMessages.map(\.id))
                )
            }
        )
    }

    func goToEndButton(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollMomentumProxy.stopMomentum()
            claimViewportForExplicitFollow(proxy: proxy)
            scrollState.isScrollingToBottom = true
            scrollState.goToEndRequested = true
            scrollState.userIsScrolledAway = false
        } label: {
            HStack(spacing: Layout.goToEndSpacing) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                Text("Go to End")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
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
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: transcriptColorScheme))
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
                            .foregroundStyle(Theme.mutedForeground(for: transcriptColorScheme))
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(prompt))
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(Theme.foreground(for: transcriptColorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                    }
                    .padding(.horizontal, Layout.suggestedPromptHorizontalPadding)
                    .padding(.vertical, Layout.suggestedPromptVerticalPadding)
                    .background(Theme.muted(for: transcriptColorScheme).opacity(Layout.suggestedPromptBackgroundOpacity))
                    .clipShape(RoundedRectangle(cornerRadius: Layout.suggestedPromptCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.suggestedPromptCornerRadius)
                            .strokeBorder(
                                Theme.border(for: transcriptColorScheme).opacity(Layout.suggestedPromptBorderOpacity),
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
                .foregroundStyle(Theme.mutedForeground(for: transcriptColorScheme))
            Text("Showing the most recent \(viewModel.filteredMessages.count) of \(viewModel.totalMessageCount) messages.\nSee the full conversation on the desktop app.")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: transcriptColorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Layout.truncationBannerHorizontalPadding)
        .padding(.vertical, Layout.truncationBannerVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(Theme.muted(for: transcriptColorScheme).opacity(Layout.truncationBannerBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.truncationBannerCornerRadius))
    }
}
