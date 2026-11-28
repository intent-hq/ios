import SwiftUI

extension ConversationTranscriptView {
    func handleTranscriptAppearance(proxy: ScrollViewProxy) {
        beginViewportTrace()
        send(.viewAppeared, proxy: proxy)
        restoreRetainedViewport(proxy: proxy)
        if !viewModel.isLoading {
            runInitialScrollIfNeeded(proxy: proxy)
        }
    }

    func restoreRetainedViewport(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        let revision = scrollState.viewportOwnershipRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.initialScrollDelay) {
            guard lifecycle.isVisible, revision == scrollState.viewportOwnershipRevision,
                  !isUserInteracting, !isFollowing,
                  scrollMomentumProxy.scrollView?.window != nil else {
                traceSnapshot("restoreSkipped requestedOwnership=\(revision)")
                return
            }
            scrollState.retainViewportMessages(withIDs: viewModel.filteredMessageIDs)
            guard let target = scrollState.resumeViewportTarget() else {
                traceEvent("RestoreSkipped", "reason=noRetainedTarget")
                return
            }
            guard viewModel.filteredMessageIDs.contains(target) else {
                scrollState.retireViewportRestoration()
                return
            }
            if viewModel.filteredMessages.suffix(Self.eagerTailMessageLimit).contains(where: { $0.id == target }) {
                proxy.scrollTo("transcript-tail", anchor: .top)
                let ownership = scrollState.viewportOwnershipRevision
                DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.initialScrollDelay) {
                    guard lifecycle.isVisible, ownership == scrollState.viewportOwnershipRevision,
                          !isUserInteracting, !isFollowing else { return }
                    alignRetainedViewport(target: target, proxy: proxy)
                }
            } else {
                alignRetainedViewport(target: target, proxy: proxy)
            }
        }
    }

    private func alignRetainedViewport(target: String, proxy: ScrollViewProxy) {
        let generation = scrollState.initialScrollGeneration
        let ownershipRevision = scrollState.viewportOwnershipRevision
        traceEvent("RestoreRequested", "target=\(target)")
        proxy.scrollTo(target, anchor: .top)
        scrollState.retainedViewportScrollIssued(target: target, generation: generation, ownershipRevision: ownershipRevision)
    }

    func handleMessageCountChange(from oldIDs: [String], to newIDs: [String], proxy: ScrollViewProxy) {
        guard lifecycle.isVisible || newIDs.isEmpty else { return }
        traceEvent("MessageIDsChanged", "old=\(oldIDs.count) new=\(newIDs.count)")
        scheduleTraceSnapshots()
        let oldCount = oldIDs.count
        let newCount = newIDs.count
        switch ConversationTranscriptScrollPolicy.messageCountChangeDecision(
            from: oldCount,
            to: newCount,
            hasInitiallyScrolled: hasInitiallyScrolled,
            isPrepend: ConversationTranscriptScrollPolicy.isHistoryPrepend(from: oldIDs, to: newIDs)
        ) {
        case .preserveViewport:
            return
        case .rearmEntryScroll:
            cancelPastEndRePin()
            cancelDeferredContainerRePin()
            cancelBottomBandRePin()
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
        let appendedUserMessage = newCount > oldCount && oldIDs.last != newIDs.last
            && viewModel.filteredMessages.last?.role == .user
        if appendedUserMessage {
            claimViewportForExplicitFollow(proxy: proxy)
            scrollState.userIsScrolledAway = false
        }
        if shouldFollowToBottom {
            scrollToBottom(proxy: proxy, forced: appendedUserMessage)
        }
    }

    var shouldFollowToBottom: Bool {
        ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    func runInitialScrollIfNeeded(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        guard !scrollState.entryScroll.isScheduled else {
            traceEvent("EntrySkipped", "reason=alreadyScheduled")
            return
        }
        traceSnapshot("entryScheduled")
        scrollState.entryScroll = .scheduled
        let generation = scrollState.initialScrollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.initialScrollDelay) {
            performInitialScrollWhenReady(
                proxy: proxy,
                scrollViewWaitElapsed: false,
                generation: generation
            )
        }
    }

    func handleScrollViewResolved(proxy: ScrollViewProxy) {
        guard lifecycle.isVisible else { return }
        let generation = scrollState.initialScrollGeneration
        guard scrollState.entryScroll == .awaitingScrollView else {
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

    private func performInitialScrollWhenReady(
        proxy: ScrollViewProxy,
        scrollViewWaitElapsed: Bool,
        generation: Int
    ) {
        guard lifecycle.isVisible else { return }
        guard generation == scrollState.initialScrollGeneration else {
            traceEvent("EntrySkipped", "reason=staleGeneration requested=\(generation)")
            return
        }
        let step = ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: scrollState.entryScroll.isPerformed,
            scrollViewResolved: scrollMomentumProxy.hasResolvedScrollView,
            scrollViewWaitElapsed: scrollViewWaitElapsed,
            entryMetadataReady: viewModel.isEntryScrollReady
        )
        traceEvent("EntryDecision", "step=\(step) ready=\(viewModel.isEntryScrollReady) resolved=\(scrollMomentumProxy.hasResolvedScrollView) waitElapsed=\(scrollViewWaitElapsed)")
        switch step {
        case .skip:
            return
        case .preserveViewport:
            scrollState.preservePresentedViewport(distanceToBottom: ConversationTranscriptScrollPolicy.preservedEntryDistanceToBottom(
                scrollMomentumProxy.distanceToBottom,
                endRecoveryArmed: lifecycle.currentRecovery != nil,
                isInteracting: isUserInteracting
            ))
        case .waitForScrollView:
            scrollState.entryScroll = .awaitingScrollView
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
            scrollState.entryScroll = .settling
            performInitialScroll(proxy: proxy, generation: generation)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.Conversation.Transcript.initialScrollSettleDelay
            ) {
                guard generation == scrollState.initialScrollGeneration else { return }
                scrollState.pendingEntryDivider = nil
                scrollState.entryScroll = .positioned
            }
        }
    }

    private func performInitialScroll(proxy: ScrollViewProxy, generation: Int) {
        guard let dividerAnchor = viewModel.newMessagesDividerAnchorId else {
            traceEvent("EntryTarget", "target=end")
            scrollToBottom(proxy: proxy, forced: true, animated: false)
            return
        }
        scrollState.pendingEntryDivider = dividerAnchor
        traceEvent("EntryTarget", "target=divider row=\(dividerAnchor)")
        proxy.scrollTo(dividerAnchor, anchor: .bottom)
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Transcript.dividerProbeDelay) {
            scrollState.applyDividerProbe(
                distanceToBottom: scrollMomentumProxy.distanceToBottom,
                generation: generation
            )
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
