import SwiftUI

struct ConversationTranscriptView: View {
    typealias Layout = Constants.Conversation.Transcript

    nonisolated static let viewportCoordinateSpace = "conversation-transcript-viewport"

    let viewModel: ConversationViewModel
    let scrollState: ConversationTranscriptScrollState
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.collapseToolActivity) private var collapseToolActivity
    @Environment(\.workspaceTranscriptDesign) var usesWorkspaceDesign
    @Environment(\.conversationPresentation) var presentation
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ScaledMetric(relativeTo: .caption) var actionIconSide: CGFloat = 12
    @State private var viewportContentHeight: CGFloat = 0

    typealias Lifecycle = ConversationTranscriptRecoveryLifecycle

    var transcriptColorScheme: ColorScheme { colorScheme }

    var transcriptRowSpacing: CGFloat {
        if presentation == .iPad { return Constants.Conversation.Design.IPad.transcriptRowSpacing }
        return usesWorkspaceDesign ? Constants.Conversation.Design.sectionSpacing : Layout.transcriptRowSpacing
    }

    private var transcriptHorizontalInset: CGFloat {
        if presentation == .iPad { return 0 }
        return usesWorkspaceDesign ? Constants.Conversation.Design.horizontalInset : Layout.transcriptHorizontalPadding
    }

    var scrollMomentumProxy: ScrollViewMomentumProxy {
        scrollState.momentumProxy
    }

    var lifecycle: Lifecycle.State {
        scrollState.lifecycle
    }

    var followOwnsViewport: Bool {
        if case .follow = lifecycle.owner { return true }
        return false
    }

    var userIsScrolledAway: Bool { scrollState.userIsScrolledAway }
    var hasInitiallyScrolled: Bool { scrollState.hasInitiallyScrolled }
    var isScrollingToBottom: Bool { scrollState.isScrollingToBottom }

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
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            logKeyboardGeometry("will-show", notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { notification in
            logKeyboardGeometry("did-show", notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            logKeyboardGeometry("will-hide", notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { notification in
            logKeyboardGeometry("did-hide", notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            logKeyboardGeometry("will-change-frame", notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
            logKeyboardGeometry("did-change-frame", notification: notification)
        }
        #endif
    }
}

private extension ConversationTranscriptView {
    private func transcriptScrollView(
        proxy: ScrollViewProxy,
        dividerAnchorId: String?
    ) -> some View {
        transcriptScrollBase(proxy: proxy, dividerAnchorId: dividerAnchorId)
            .onChange(of: viewModel.filteredMessages.map(\.id)) { oldIDs, newIDs in
                handleMessageCountChange(from: oldIDs, to: newIDs, proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, isStreaming in
                if ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
                    isStreaming: isStreaming,
                    hasInitiallyScrolled: hasInitiallyScrolled,
                    userIsScrolledAway: userIsScrolledAway
                ) {
                    scrollToBottom(proxy: proxy, forced: true)
                } else if !isStreaming {
                    scheduleBottomBandRePinIfNeeded(proxy: proxy)
                }
            }
            .onChange(of: viewModel.store.streamingUpdateCount) { _, _ in
                followStreamingDeltaIfDrifted(proxy: proxy)
            }
            .onChange(of: viewModel.isLoading) { _, isLoading in
                traceEvent("LoadingChanged", "loading=\(isLoading)")
                if !isLoading {
                    scheduleTraceSnapshots()
                    runInitialScrollIfNeeded(proxy: proxy)
                }
            }
            .onChange(of: viewModel.isEntryScrollReady) { _, ready in
                if ready { runInitialScrollIfNeeded(proxy: proxy) }
            }
            .onAppear {
                handleTranscriptAppearance(proxy: proxy)
            }
            .onChange(of: scrollMomentumProxy.hostingRevision) { _, _ in
                traceSnapshot("hostingChanged")
                restoreRetainedViewport(proxy: proxy)
                if scrollMomentumProxy.hasResolvedScrollView {
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
                    followGoToEndRequest(proxy: proxy)
                }
            }
    }

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
            LazyVStack(spacing: transcriptRowSpacing) {
                transcriptRows(proxy: proxy, dividerAnchorId: dividerAnchorId)
            }
            .padding(.horizontal, transcriptHorizontalInset)
            .padding(.top, Layout.transcriptTopPadding)
            // Keep short transcripts bottom-aligned when the keyboard changes the viewport.
            .frame(minHeight: viewportContentHeight, alignment: .bottom)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                scrollState.rowHeightCache.updateLayoutWidth(width)
            }
            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
        }
        .defaultScrollAnchor(.bottom)
        .coordinateSpace(name: Self.viewportCoordinateSpace)
        .scrollIndicators(.hidden)
        .modifier(ConversationScrollEdgeEffect())
        .scrollBounceBehavior(.always)
        .accessibilityIdentifier("transcript.scrollView")
        .demoAccessibilityValue(transcriptDemoReport)
        .demoStartupGestureProbe(scrollState: scrollState)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.visibleRect.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
        } action: { _, height in
            viewportContentHeight = height
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            ConversationTranscriptScrollPolicy.isNearHistoryTop(
                contentOffsetY: geometry.contentOffset.y,
                topInset: geometry.contentInsets.top,
                viewportHeight: geometry.visibleRect.height
            )
        } action: { _, isNearTop in
            guard lifecycle.isVisible else { return }
            scrollState.isNearHistoryTop = isNearTop
            loadOlderMessagesIfNeeded(proxy: proxy)
        }
        #if DEBUG
        .demoEndDerealization(
            triggerFile: DemoFixtures.configuredEndDerealizationTriggerFile,
            onTrigger: withdrawEndRowForDemo,
            onGeometryChange: restoreDerealizedEndIfMoved
        )
        #endif
        .onChange(of: dynamicTypeSize) { _, _ in
            scrollState.rowHeightCache.invalidateAll()
        }
        .onChange(of: collapseToolActivity) { _, _ in
            scrollState.rowHeightCache.invalidateAll()
        }
        .onScrollGeometryChange(for: ScrolledAwayGeometry.self) { geometry in
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
        .onScrollPhaseChange { oldPhase, newPhase, context in
            guard lifecycle.isVisible else { return }
            traceEvent("ScrollPhase", "old=\(oldPhase) new=\(newPhase)")
            traceSnapshot("scrollPhase")
            scrollState.isUserScrollPhase = newPhase.isUserDriven
            logScrollGeometry("phase \(oldPhase)->\(newPhase)")
            if newPhase.isUserDriven {
                takeOverPendingFollowIfGesture(isInteracting: true, proxy: proxy)
                if hasInitiallyScrolled {
                    scrollState.hasScrolledForHistory = true
                    loadOlderMessagesIfNeeded(proxy: proxy)
                }
            } else {
                scrollState.observeViewportGesture(isInteracting: false)
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
            traceSnapshot("disappear")
            send(.viewDisappeared, proxy: proxy)
            scrollState.olderMessagesTask?.cancel()
            scrollState.olderMessagesTask = nil
            scrollState.hasScrolledForHistory = false
            scrollState.isNearHistoryTop = false
            scrollState.suspendViewport()
            scrollState.suspendEntryScroll()
            scrollState.isScrollingToBottom = false
            scrollState.isUserScrollPhase = false
            scrollState.goToEndRequested = false
            cancelPastEndRePin()
            cancelDeferredContainerRePin()
            cancelBottomBandRePin()
            scrollState.trace.stop()
        }
    }
}

private extension ScrollPhase {
    var isUserDriven: Bool {
        self == .tracking || self == .interacting || self == .decelerating
    }
}
