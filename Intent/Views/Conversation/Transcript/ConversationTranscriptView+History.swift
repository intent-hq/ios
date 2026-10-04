import SwiftUI

extension ConversationTranscriptView {
    @ViewBuilder
    func olderMessagesRow(proxy: ScrollViewProxy) -> some View {
        if viewModel.isLoadingOlderMessages {
            ProgressView("Loading earlier messages")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("transcript.historyLoading")
        } else if viewModel.olderMessagesError != nil {
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
            scrollState.olderMessagesTask = nil
            if firstID != viewModel.filteredMessages.first?.id {
                preserveHistoryPosition(proxy: proxy)
            }
        }
    }

    private func preserveHistoryPosition(proxy: ScrollViewProxy) {
        // The load returns on the main actor before the inserted rows lay out.
        // Use the latest measured position, not the position at request time:
        // the reader may have kept scrolling while the network was pending.
        guard hasInitiallyScrolled, userIsScrolledAway, !isFollowing else { return }
        scrollState.suspendViewport()
        // Wait for the new lazy-stack layout before resolving the row ID;
        // scrolling now would resolve it against the pre-insertion frames.
        restoreRetainedViewport(proxy: proxy)
    }
}
