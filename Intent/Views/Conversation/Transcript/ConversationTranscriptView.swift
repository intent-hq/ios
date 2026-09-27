import SwiftUI

// Keep the ordered observation wiring here. Presentation, entry, follow,
// recovery, geometry re-pinning, and demo support live in named extensions;
// none introduces a new view identity, observation boundary, or state owner.
struct ConversationTranscriptView: View {
    typealias Layout = Constants.Conversation.Transcript

    let viewModel: ConversationViewModel
    let scrollState: ConversationTranscriptScrollState
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    typealias Lifecycle = ConversationTranscriptRecoveryLifecycle

    var transcriptColorScheme: ColorScheme { colorScheme }

    var scrollMomentumProxy: ScrollViewMomentumProxy {
        scrollState.momentumProxy
    }

    var lifecycle: Lifecycle.State {
        scrollState.lifecycle
    }

    /// A follow is pending: in its debounce, or verifying its landing.
    var followOwnsViewport: Bool {
        if case .follow = lifecycle.owner { return true }
        return false
    }

    // Read-only conveniences for the extensions. Mutations still target the
    // same parent-owned scrollState; no mutable forwarding API is exposed.
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
    }
}

private extension ConversationTranscriptView {
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
                handleMessageCountChange(from: oldCount, to: newCount, proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, isStreaming in
                if ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
                    isStreaming: isStreaming,
                    hasInitiallyScrolled: hasInitiallyScrolled,
                    userIsScrolledAway: userIsScrolledAway
                ) {
                    scrollToBottom(proxy: proxy, forced: true)
                } else if !isStreaming {
                    // The last delta and the thinking indicator leaving (or
                    // the suggested prompts arriving) can rest a short
                    // transcript short of the bottom (#346).
                    scheduleBottomBandRePinIfNeeded(proxy: proxy)
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
            .onChange(of: viewModel.isEntryScrollReady) { _, ready in
                if ready { runInitialScrollIfNeeded(proxy: proxy) }
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
                let goToEndRequested = scrollState.goToEndRequested
                scrollState.goToEndRequested = false
                if scrolledAway {
                    cancelPendingFollowOnTakeover(proxy: proxy)
                } else if ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
                    goToEndRequested: goToEndRequested
                ) {
                    scrollToBottom(proxy: proxy, forced: true)
                }
            }
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

    // This modifier chain is one scroll-state machine: splitting it would hide
    // the ordering between gesture, geometry, and past-end observations.
    // swiftlint:disable:next function_body_length
    private func transcriptScrollBase(proxy: ScrollViewProxy, dividerAnchorId: String?) -> some View {
        ScrollView {
            LazyVStack(spacing: Layout.transcriptRowSpacing) {
                transcriptRows(proxy: proxy, dividerAnchorId: dividerAnchorId)
            }
            .scrollTargetLayout()
            .padding(.horizontal, Layout.transcriptHorizontalPadding)
            .padding(.top, Layout.transcriptTopPadding)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                scrollState.rowHeightCache.updateLayoutWidth(width)
            }
            // Hosted on the stack itself, not a lazily realized row, so the
            // UIScrollView is found regardless of which rows exist.
            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: Binding(
            get: { scrollState.visibleMessageID },
            set: { scrollState.visibleMessageID = $0 }
        ))
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        .accessibilityIdentifier("transcript.scrollView")
        .demoAccessibilityValue(
            ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(
                outcome: scrollState.lastForcedFollowOutcome,
                corrections: scrollState.lastForcedFollowCorrections,
                endRecovery: unrealizedEndRecoveryDemoReport.summary
            )
        )
        .demoEndDerealization(
            triggerFile: DemoFixtures.configuredEndDerealizationTriggerFile,
            onTrigger: withdrawEndRowForDemo,
            onGeometryChange: restoreDerealizedEndIfMoved
        )
        .onChange(of: dynamicTypeSize) { _, _ in
            scrollState.rowHeightCache.invalidateAll()
        }
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
            takeOverPendingFollowIfGesture(proxy: proxy)
            if rePinAfterContainerHeightChange(
                from: old.containerHeight, to: new.containerHeight, proxy: proxy
            ) { return }
            applyScrolledAwayEdge(geometryAway: new.isScrolledAway, proxy: proxy)
            scheduleBottomBandRePinIfNeeded(proxy: proxy)
        }
        // A user-driven phase beginning takes over whatever follow is pending
        // (see `takeOverPendingFollowIfGesture`). A gesture's last geometry
        // edge can arrive after UIKit has cleared its deceleration flag, and
        // the band observer above drops a flip that reverses within one
        // layout pass (#280); the phase ending is one authoritative sample of
        // where the gesture left the viewport. An explicit follow that cut
        // the gesture short (Go to End stopping a fling, the tap that sent a
        // message) owns the flag instead.
        .onScrollPhaseChange { oldPhase, newPhase, context in
            scrollState.isUserScrollPhase = newPhase.isUserDriven
            if newPhase.isUserDriven {
                takeOverPendingFollowIfGesture(isInteracting: true, proxy: proxy)
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
                scheduleRePinIfRestingPastEnd(proxy: proxy)
            }
        }
        .onDisappear {
            cancelPastEndRePin()
            cancelDeferredContainerRePin()
            cancelBottomBandRePin()
            send(.viewDisappeared, proxy: proxy)
        }
    }
}

private extension ScrollPhase {
    /// Phases driven by the user's finger or the deceleration after it;
    /// `.animating` is a programmatic scroll and `.idle` is at rest.
    var isUserDriven: Bool {
        self == .tracking || self == .interacting || self == .decelerating
    }
}
