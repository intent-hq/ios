import CoreGraphics
@testable import Intent
import Observation
import Synchronization
import Testing

extension ConversationTranscriptScrollPolicyTests {
    @Test @MainActor func issuedRetainedScrollWaitsForTheObservedLanding() {
        // Native afc4c21: a fresh owner-token measurement arrived before the
        // asynchronous scrollTo moved the row, despite the command returning.
        let savedY = CGFloat(52.66666666666629)
        let state = retainedRestorationState(y: savedY)
        #expect(state.resumeViewportTarget() == "row-31")
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: savedY)) == nil)
        issueRetainedScroll(state)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: savedY)) == nil)
        let landed = retainedMeasurement(state, y: -2.2737367544323206e-13)
        #expect(recordRetainedMeasurement(state, landed) == landed.frame.minY - savedY)
        #expect(recordRetainedMeasurement(state, landed) == nil)
    }

    @Test @MainActor func retainedScrollRejectsIntermediateLayoutWithFreshOwnership() {
        let state = retainedRestorationState(y: 48)
        #expect(state.resumeViewportTarget() == "row-31")
        issueRetainedScroll(state)
        let geometry = ConversationTranscriptScrollPolicy.ViewportGeometry(
            contentOffsetY: 1000, contentHeight: 2800, containerHeight: 624, topInset: 0, bottomInset: 0
        )
        for minY in [CGFloat(48), 20, 12] {
            #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: minY), geometry: geometry) == nil)
            #expect(state.viewportAnchor.hasPendingRetainedRestoration)
        }
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0), geometry: geometry) == -48)
        #expect(!state.viewportAnchor.hasPendingRetainedRestoration)
    }

    @Test(arguments: [CGFloat(0), CGFloat(20)]) @MainActor
    func retainedLandingHonorsAdjustedTopInset(inset: CGFloat) {
        let state = retainedRestorationState(y: 48)
        #expect(state.resumeViewportTarget() == "row-31")
        issueRetainedScroll(state)
        let geometry = ConversationTranscriptScrollPolicy.ViewportGeometry(
            contentOffsetY: 1000, contentHeight: 2800, containerHeight: 624, topInset: inset, bottomInset: 12
        )
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: inset + 12), geometry: geometry) == nil)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: inset), geometry: geometry) == inset - 48)
    }

    @Test @MainActor func unavailableLandingGeometryKeepsRestorationForAValidCallback() {
        let state = retainedRestorationState(y: 48)
        #expect(state.resumeViewportTarget() == "row-31")
        issueRetainedScroll(state)
        let unavailable = ConversationTranscriptScrollPolicy.ViewportGeometry(
            contentOffsetY: .nan, contentHeight: 2800, containerHeight: 624, topInset: 0, bottomInset: 0
        )
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0), geometry: unavailable) == nil)
        #expect(state.viewportAnchor.hasPendingRetainedRestoration)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0)) == -48)
    }

    private enum RetainedGeometryFixture {
        static let distance: CGFloat = 900
        static let width: CGFloat = 300
        static let rowHeight: CGFloat = 64
        static let viewportHeight: CGFloat = 624
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func deletedRetainedRowRejectsQueuedGeometry(scrollIssued: Bool, replacesRow: Bool) {
        let transcript = ConversationLiveTranscript(connectionManager: ConnectionManager.shared)
        transcript.messages = ["row-31", "survivor"].map { ConversationMessage(id: $0, role: .user) }
        let state = retainedRestorationState(y: 48)
        state.retainViewportMessages(withIDs: transcript.messageIDs)
        #expect(state.resumeViewportTarget() == "row-31")
        if scrollIssued { issueRetainedScroll(state) }
        let queued = retainedMeasurement(state, y: 0)
        let remaining: Set<String> = replacesRow ? ["survivor", "replacement"] : ["survivor"]
        #expect(ConversationTranscriptScrollPolicy.messageCountChangeDecision(from: 2, to: remaining.count, hasInitiallyScrolled: true) == (replacesRow ? .none : .rePinIfPastEnd))
        transcript.messages = remaining.map { ConversationMessage(id: $0, role: .user) }
        // A queued callback reads current membership before SwiftUI observes
        // the replacement; the warmed cache must not resurrect the deleted row.
        state.retainViewportMessages(withIDs: transcript.messageIDs)
        state.viewportAnchor.remove(id: "row-31", generation: queued.generation, entryGeneration: state.initialScrollGeneration, ownershipRevision: queued.ownershipRevision)
        #expect(state.viewportAnchor.record(id: "survivor", measurement: retainedMeasurement(state, y: 64), viewportHeight: 624, preserve: true, entryGeneration: state.initialScrollGeneration) == nil)
        #expect(recordRetainedMeasurement(state, queued) == nil)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0)) == nil)
        #expect(state.resumeViewportTarget() == nil)
        // Reusing an ID cannot resurrect the captured measurement either.
        transcript.messages = ["row-31", "survivor"].map { ConversationMessage(id: $0, role: .user) }
        state.retainViewportMessages(withIDs: transcript.messageIDs)
        #expect(recordRetainedMeasurement(state, queued) == nil)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 20)) == nil)
    }

    @Test @MainActor func deletingCoveredRetainedRowRetiresItsSavedPosition() {
        let state = retainedRestorationState(y: 48)
        state.retainViewportMessages(withIDs: ["survivor"])
        #expect(state.resumeViewportTarget() == nil)
        #expect(state.hasInitiallyScrolled && state.userIsScrolledAway)
    }

    @Test(arguments: [CGFloat(0), CGFloat(48)]) @MainActor
    func noMoveRetainedScrollSettlesOnlyOnPostCommandGeometry(savedY: CGFloat) {
        let state = retainedRestorationState(y: savedY)
        #expect(state.resumeViewportTarget() == "row-31")
        let before = retainedMeasurement(state, y: savedY)
        #expect(recordRetainedMeasurement(state, before) == nil)
        issueRetainedScroll(state)
        // A queued frame captured before the command is not its completion.
        #expect(recordRetainedMeasurement(state, before) == nil)
        // Nonzero top alignment may legitimately stay put at the content end.
        let geometry = ConversationTranscriptScrollPolicy.ViewportGeometry(
            contentOffsetY: 1000, contentHeight: 1624, containerHeight: 624, topInset: 0, bottomInset: 0
        )
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: savedY), geometry: geometry) == nil)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: savedY)) == nil)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: savedY + 20)) == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func coarseRetainedScrollRejectsPreCommandFramesAndSurvivesDerealization(derealizes: Bool) {
        let state = retainedRestorationState(y: 48)
        #expect(state.resumeViewportTarget() == "row-31")
        let queued = retainedMeasurement(state, y: 48)
        #expect(recordRetainedMeasurement(state, queued) == nil)
        // Even a different pre-command frame cannot consume the correction.
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 20)) == nil)
        issueRetainedScroll(state)
        if derealizes {
            state.viewportAnchor.remove(
                id: "row-31",
                generation: state.initialScrollGeneration,
                entryGeneration: state.initialScrollGeneration,
                ownershipRevision: state.viewportOwnershipRevision
            )
        }
        #expect(recordRetainedMeasurement(state, queued) == nil)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0)) == -48)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0)) == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func retainedScrollCompletionCannotReclaimALaterOwner(gesture: Bool) {
        let state = retainedRestorationState(y: 48)
        #expect(state.resumeViewportTarget() == "row-31")
        let revision = state.viewportOwnershipRevision
        if gesture { state.observeViewportGesture(isInteracting: true) } else { state.retireViewportRestoration() }
        let owner = state.viewportOwnershipRevision
        state.retainedViewportScrollIssued(target: "row-31", generation: state.initialScrollGeneration, ownershipRevision: revision)
        #expect(state.viewportOwnershipRevision == owner)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0)) == nil)
    }

    @Test @MainActor func retainedScrollCommandPublishesFreshGeometryExactlyOnce() {
        let state = retainedRestorationState(y: 48)
        #expect(state.resumeViewportTarget() == "row-31")
        let revision = state.viewportOwnershipRevision
        let generation = state.initialScrollGeneration
        let changes = Mutex(0)
        withObservationTracking { _ = state.viewportOwnershipRevision } onChange: { changes.withLock { $0 += 1 } }
        state.retainedViewportScrollIssued(target: "other", generation: generation, ownershipRevision: revision)
        state.retainedViewportScrollIssued(target: "row-31", generation: generation - 1, ownershipRevision: revision)
        state.retainedViewportScrollIssued(target: "row-31", generation: generation, ownershipRevision: revision - 1)
        #expect(state.viewportOwnershipRevision == revision && changes.withLock { $0 } == 0)
        issueRetainedScroll(state)
        #expect(state.viewportOwnershipRevision == revision + 1 && changes.withLock { $0 } == 1)
        state.retainedViewportScrollIssued(target: "row-31", generation: generation, ownershipRevision: revision)
        issueRetainedScroll(state)
        #expect(state.viewportOwnershipRevision == revision + 1)
        #expect(recordRetainedMeasurement(state, retainedMeasurement(state, y: 0)) == -48)
    }

    @MainActor private func retainedRestorationState(y: CGFloat) -> ConversationTranscriptScrollState {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: RetainedGeometryFixture.distance)
        state.retainViewportMessages(withIDs: ["row-31", "survivor"])
        _ = recordRetainedMeasurement(state, retainedMeasurement(state, y: y))
        state.suspendViewport()
        return state
    }

    @MainActor private func issueRetainedScroll(_ state: ConversationTranscriptScrollState) {
        state.retainedViewportScrollIssued(target: "row-31", generation: state.initialScrollGeneration, ownershipRevision: state.viewportOwnershipRevision)
    }

    @MainActor private func retainedMeasurement(_ state: ConversationTranscriptScrollState, y: CGFloat) -> ConversationTranscriptViewportAnchor.Measurement {
        .init(
            frame: CGRect(x: 0, y: y, width: RetainedGeometryFixture.width, height: RetainedGeometryFixture.rowHeight),
            divider: "seen",
            generation: state.initialScrollGeneration,
            ownershipRevision: state.viewportOwnershipRevision
        )
    }

    @MainActor private func recordRetainedMeasurement(
        _ state: ConversationTranscriptScrollState,
        _ measurement: ConversationTranscriptViewportAnchor.Measurement,
        geometry: ConversationTranscriptScrollPolicy.ViewportGeometry? = nil
    ) -> CGFloat? {
        state.viewportAnchor.record(id: "row-31", measurement: measurement, viewportHeight: RetainedGeometryFixture.viewportHeight, preserve: true, entryGeneration: state.initialScrollGeneration, scrollGeometry: geometry)
    }
}
