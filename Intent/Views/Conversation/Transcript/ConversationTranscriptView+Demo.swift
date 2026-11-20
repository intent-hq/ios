import SwiftUI

extension ConversationTranscriptView {
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

    var isDemoEndWithdrawn: Bool {
        #if DEBUG
        demoWithdrawnEnd != nil
        #else
        false
        #endif
    }

    #if DEBUG

    var demoWithdrawnEnd: ConversationTranscriptScrollState.DemoEndDerealization? {
        DemoMode.isEnabled ? scrollState.demoEndDerealization : nil
    }

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

    @ViewBuilder
    func demoAccessibilityValue(_ value: @autoclosure () -> String) -> some View {
        #if DEBUG
        if DemoMode.isEnabled {
            accessibilityValue(value())
        } else {
            self
        }
        #else
        self
        #endif
    }

    #if DEBUG
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
