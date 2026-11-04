import SwiftUI

extension ConversationTranscriptView {
    /// A preserved entry has no forced follow to finish. Keep that distinct
    /// from a requested follow, and expose the actual authority/owner state.
    var transcriptDemoReport: String {
        var follow = ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(
            outcome: scrollState.lastForcedFollowOutcome,
            corrections: scrollState.lastForcedFollowCorrections,
            endRecovery: unrealizedEndRecoveryDemoReport.summary
        )
        if scrollState.lastForcedFollowOutcome == nil { follow += " " + unrealizedEndRecoveryDemoReport.summary }
        let entry = scrollState.entryViewportPreserved ? "preserved" : (hasInitiallyScrolled ? "positioned" : "pending")
        return follow + " entry=\(entry) metadataReady=\(viewModel.isEntryScrollReady)"
            + " forcedRequested=\(scrollState.hasRequestedForcedFollow) followActive=\(isFollowing)"
            + " forcedRequests=\(scrollState.forcedFollowRequestCount)"
            + " phase=\(isUserInteracting ? "gesture" : "idle")"
            + " workspace=\(viewModel.store.workspaceId ?? "pending")"
            + " historyCount=\(viewModel.filteredMessages.count) historyLoading=\(viewModel.isLoadingOlderMessages) olderAvailable=\(viewModel.hasOlderMessages)"
            + demoRecoveryResizeReport
    }

    /// The last episode's report or, with one in flight (`recovering`) or
    /// none armed yet (`notAttempted`), the classifier's reading of the
    /// current state.
    var unrealizedEndRecoveryDemoReport: ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport {
        scrollState.lastUnrealizedEndRecoveryReport
            ?? ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport(
                outcome: nil,
                corrections: scrollState.unrealizedEndRecoveryCorrections,
                episodes: scrollState.unrealizedEndRecoveryEpisodes,
                endRealized: lifecycle.isEndRealized,
                cancelled: false
            )
    }

    // MARK: - Demo-only controlled end derealization (#338)

    /// True only while a Debug demo has withdrawn the end row; always false
    /// in Release, where the demo fixtures are compiled out.
    var isDemoEndWithdrawn: Bool {
        #if DEBUG
        demoWithdrawnEnd != nil
        #else
        false
        #endif
    }

    #if DEBUG

    /// Nil outside `--demo-data` without reading the state, so production
    /// bodies take no dependency on it.
    var demoWithdrawnEnd: ConversationTranscriptScrollState.DemoEndDerealization? {
        DemoMode.isEnabled ? scrollState.demoEndDerealization : nil
    }

    /// Withdraws the end row once the trigger file exists
    /// (`DemoFixtures.configuredEndDerealizationTriggerFile`): the marker leaves the
    /// lazy stack, its real `onDisappear` arms the recovery through the
    /// ordinary `.endDerealized` edge, and the recovery runs unchanged — nothing
    /// it reads is fabricated. Waits for the live scroll view so the offset
    /// the restore is judged against is the one the recovery pages from.
    func withdrawEndRowForDemo() async {
        guard !scrollState.demoEndDerealizationTriggered else { return }
        while scrollMomentumProxy.restingGeometry == nil {
            try? await Task.sleep(for: DemoFixtures.triggerFilePollInterval)
            guard !Task.isCancelled else { return }
        }
        guard let geometry = scrollMomentumProxy.restingGeometry else { return }
        scrollState.demoEndDerealizationTriggered = true
        let mode = DemoFixtures.configuredEndDerealizationMode
        AppLog.userInterface.debug("[SCROLL] Demo: withdrawing the end row (\(mode.rawValue)) at \(geometry.contentOffsetY)")
        scrollState.demoEndDerealization = ConversationTranscriptScrollState.DemoEndDerealization(
            mode: mode,
            withdrawnOffsetY: geometry.contentOffsetY
        )
    }

    /// Puts the withdrawn end row back on evidence from the live scroll view
    /// alone (see `DemoFixtures.shouldRestoreDerealizedEnd`): the recovery's
    /// page up in `release` mode, or a gesture in either. Restored at the
    /// end of the content while the viewport rests above it, the marker is
    /// unrealized until the recovery's own follow back reaches it, so its
    /// real `onAppear` is what resolves the episode.
    func restoreDerealizedEndIfMoved() {
        guard let withdrawn = demoWithdrawnEnd,
              let geometry = scrollMomentumProxy.restingGeometry,
              DemoFixtures.shouldRestoreDerealizedEnd(
                mode: withdrawn.mode,
                withdrawnOffsetY: withdrawn.withdrawnOffsetY,
                contentOffsetY: geometry.contentOffsetY,
                containerHeight: geometry.containerHeight,
                isInteracting: isUserInteracting
              )
        else { return }
        AppLog.userInterface.debug("[SCROLL] Demo: restoring the end row at \(geometry.contentOffsetY)")
        releaseHooksRowDuringDemoRecovery(geometry: geometry)
        scrollState.demoEndDerealization = nil
    }
    #endif
}

extension View {
    /// Only the startup/history demos expose this live query surface. The one-point
    /// overlay does not participate in transcript layout or receive gestures.
    @ViewBuilder
    func demoStartupGestureProbe(scrollState: ConversationTranscriptScrollState) -> some View {
        #if DEBUG
        if DemoMode.isEnabled, DemoFixtures.usesStartupTranscript || DemoFixtures.usesHistoryPages {
            overlay(alignment: .topLeading) {
                TranscriptGestureProbe(scrollState: scrollState)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Under `--demo-data` only: exposes `value` as the view's accessibility
    /// value so the XCUITests can read the transcript's landing outcome.
    /// Zero-impact otherwise — the value is neither computed (so the observed
    /// state behind it is not a body dependency) nor applied.
    @ViewBuilder
    func demoAccessibilityValue(_ value: @autoclosure () -> String) -> some View {
        if DemoMode.isEnabled {
            accessibilityValue(value())
        } else {
            self
        }
    }

    #if DEBUG
    /// Under `--demo-data` with `--demo-end-derealization-trigger-file` only:
    /// polls for the trigger file and calls `onTrigger` once it exists, and
    /// calls `onGeometryChange` on every content offset change so the
    /// withdrawn end row can be restored on live evidence (#338). Neither
    /// the task nor the observer is installed otherwise.
    @ViewBuilder
    func demoEndDerealization(
        triggerFile: URL?,
        onTrigger: @escaping @MainActor () async -> Void,
        onGeometryChange: @escaping @MainActor () -> Void
    ) -> some View {
        if DemoMode.isEnabled, let triggerFile {
            self
                .task {
                    guard (try? await DemoFixtures.wait(for: .triggerFile(triggerFile))) != nil else { return }
                    await onTrigger()
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, _ in
                    onGeometryChange()
                }
        } else {
            self
        }
    }
    #endif
}

private struct TranscriptGestureProbe: UIViewRepresentable {
    let scrollState: ConversationTranscriptScrollState

    func makeUIView(context _: Context) -> TranscriptGestureAccessibilityView {
        let view = TranscriptGestureAccessibilityView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "transcript.gestureState"
        view.accessibilityLabel = "Transcript gesture state"
        view.isUserInteractionEnabled = false
        view.scrollState = scrollState
        return view
    }

    func updateUIView(_ view: TranscriptGestureAccessibilityView, context _: Context) {
        view.scrollState = scrollState
    }

    static func dismantleUIView(_ view: TranscriptGestureAccessibilityView, coordinator _: Void) {
        view.scrollState = nil
    }
}
