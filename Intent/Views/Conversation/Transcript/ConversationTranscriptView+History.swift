import SwiftUI

extension ConversationTranscriptView {
    @ViewBuilder
    func olderMessagesRow(proxy: ScrollViewProxy) -> some View {
        if viewModel.olderMessagesError != nil {
            Button("Couldn't load earlier messages — Retry") {
                requestOlderMessages(proxy: proxy)
            }
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
            let firstID = viewModel.filteredMessages.first?.id
            await viewModel.loadOlderMessages()
            guard !Task.isCancelled else { return }
            if firstID != viewModel.filteredMessages.first?.id {
                preserveHistoryPosition(proxy: proxy)
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

    private func preserveHistoryPosition(proxy: ScrollViewProxy) {
        // The load returns on the main actor before the inserted rows lay out.
        // Use the latest measured position, not the position at request time:
        // the reader may have kept scrolling while the network was pending.
        // SwiftUI owns the offset under an active drag/deceleration. Starting
        // a manual restoration then would either fight it or leave a retained
        // target whose scheduled scroll is refused while the gesture is active.
        guard hasInitiallyScrolled, userIsScrolledAway, !isFollowing, !isUserInteracting else { return }
        scrollState.suspendViewport()
        // Wait for the new lazy-stack layout before resolving the row ID;
        // scrolling now would resolve it against the pre-insertion frames.
        restoreRetainedViewport(proxy: proxy)
    }
}
