import SwiftUI

extension ConversationTranscriptView {
    @ViewBuilder
    func olderMessagesRow(proxy: ScrollViewProxy) -> some View {
        if viewModel.olderMessagesError != nil {
            Button("Couldn't load earlier messages — Retry") {
                requestOlderMessages(proxy: proxy)
            }
            .buttonStyle(IntentContentButtonStyle())
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("transcript.historyRetry")
        } else if !viewModel.hasOlderMessages, !viewModel.isLoading, !viewModel.filteredMessages.isEmpty {
            Text("Beginning of conversation")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("transcript.historyBeginning")
        }
    }

    func loadOlderMessagesIfNeeded(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        guard ConversationTranscriptScrollPolicy.shouldLoadOlderMessages(
            isNearTop: scrollState.isNearHistoryTop,
            hasInitiallyScrolled: hasInitiallyScrolled,
            hasUserScrolled: scrollState.hasScrolledForHistory,
            isFollowing: isFollowing,
            canRequestPage: viewModel.hasOlderMessages && !viewModel.isLoadingOlderMessages && viewModel.olderMessagesError == nil
        ) else { return }
        requestOlderMessages(proxy: proxy)
    }

    private func requestOlderMessages(proxy: ScrollViewProxy) {
        guard scrollState.olderMessagesTask == nil, viewModel.hasOlderMessages else { return }
        scrollState.olderMessagesTask = Task { @MainActor in
            await viewModel.loadOlderMessages {
                preserveHistoryPosition()
            }
            guard !Task.isCancelled else { return }
            if scrollState.hasPendingViewportRestoration {
                restoreRetainedViewport(proxy: proxy)
            }
            // A prepend can leave the reader inside the prefetch band without
            // crossing its Boolean geometry edge again. Wait for layout and
            // retained-position restoration before measuring the new top;
            // otherwise a fast response could drain pages against old frames.
            repeat {
                try? await Task.sleep(for: .seconds(Layout.initialScrollDelay))
                guard !Task.isCancelled else { return }
            } while scrollState.hasPendingViewportRestoration
            scrollState.olderMessagesTask = nil
            guard let geometry = scrollMomentumProxy.restingGeometry else { return }
            scrollState.isNearHistoryTop = ConversationTranscriptScrollPolicy.isNearHistoryTop(
                contentOffsetY: geometry.contentOffsetY,
                topInset: geometry.topInset,
                viewportHeight: geometry.containerHeight
            )
            loadOlderMessagesIfNeeded(proxy: proxy)
        }
    }

    private func preserveHistoryPosition() {
        // Called synchronously at page acceptance, before observable rows change.
        // Request-time frames may be stale if the reader continued scrolling;
        // post-await frames may already describe the newly inserted history.
        guard lifecycle.isVisible, hasInitiallyScrolled, userIsScrolledAway,
              !isFollowing, !isUserInteracting else { return }
        scrollState.suspendViewport()
    }
}
