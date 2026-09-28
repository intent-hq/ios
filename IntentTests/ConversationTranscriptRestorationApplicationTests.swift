import CoreGraphics
@testable import Intent
import Testing

extension ConversationTranscriptScrollPolicyTests {
    @MainActor private final class RetainedLayoutFixture {
        let rowContentY: CGFloat = 1557.3333333333333
        let savedOffset: CGFloat = 1505.6666666666667
        let contentHeight: CGFloat = 2787
        let viewportHeight: CGFloat = 624.3333333333333
        let rowX: CGFloat = 16
        let rowWidth: CGFloat = 361
        let rowHeight: CGFloat = 49.33333333333326
        var offset: CGFloat = 1557.3333333333333
        var pendingAlignment: CGFloat = 0
        var writes: [CGFloat] = []
        var alignments: [CGFloat] = []

        var geometry: ConversationTranscriptScrollPolicy.ViewportGeometry {
            .init(contentOffsetY: offset, contentHeight: contentHeight, containerHeight: viewportHeight, topInset: 0, bottomInset: 0)
        }

        func apply(to state: ConversationTranscriptScrollState) {
            let application = state.viewportAnchor.application(
                id: "row-31",
                measurement: .init(
                    frame: CGRect(x: rowX, y: rowContentY - offset, width: rowWidth, height: rowHeight),
                    divider: "seen",
                    generation: state.initialScrollGeneration,
                    ownershipRevision: state.viewportOwnershipRevision
                ),
                geometry: geometry,
                preserve: true,
                entryGeneration: state.initialScrollGeneration
            )
            switch application {
            case .offset(let value):
                writes.append(value)
                offset = value
            case let .retainedAlignment(target, anchor, _):
                #expect(target.messageID == "row-31")
                alignments.append(anchor)
                pendingAlignment = anchor
            case nil:
                break
            }
        }

        func finishLayout() {
            // Replay the observed delayed coarse alignment. A final SwiftUI
            // command replaces it; a native offset write leaves it pending.
            let span = geometry.containerHeight - ConversationTranscriptViewportAnchor.restorationMarkerHeight
            offset = rowContentY - pendingAlignment * span
        }
    }

    @Test @MainActor func retainedApplicationReplacesTheCoarseTargetThatOverwroteANativeWrite() {
        let fixture = RetainedLayoutFixture()
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        state.retainViewportMessages(withIDs: ["row-31"])
        fixture.offset = fixture.savedOffset
        fixture.apply(to: state)
        state.suspendViewport()
        #expect(state.resumeViewportTarget() == "row-31")
        state.retainedViewportScrollIssued(target: "row-31", generation: state.initialScrollGeneration, ownershipRevision: state.viewportOwnershipRevision)
        fixture.apply(to: state)
        fixture.offset = fixture.rowContentY
        fixture.apply(to: state)
        fixture.apply(to: state)
        fixture.finishLayout()
        fixture.apply(to: state)
        #expect(abs(fixture.offset - fixture.savedOffset) < 0.001)
        #expect(fixture.alignments.count == 1)
        #expect(fixture.writes.isEmpty)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 48, width: 300, height: 64),
        CGRect(x: 0, y: -20, width: 300, height: 64),
        CGRect(x: 0, y: -80, width: 300, height: 600),
        CGRect(x: 0, y: -120, width: 300, height: 900),
        CGRect(x: 0, y: 48, width: 300, height: 600)
    ]) @MainActor
    func retainedMarkerAlignmentHandlesPartialAndViewportSizedRows(frame: CGRect) throws {
        let state = applicationState(frame: frame)
        let geometry = applicationGeometry()
        let action = try #require(application(state, y: 0, geometry: geometry, height: frame.height))
        guard case let .retainedAlignment(target, anchorY, rowY) = action else {
            Issue.record("Retained placement must replace the SwiftUI target")
            return
        }
        #expect(target.messageID == "row-31" && rowY == frame.minY)
        let projected = anchorY * (geometry.containerHeight - ConversationTranscriptViewportAnchor.restorationMarkerHeight)
        #expect(abs(projected - frame.minY) < 0.001)
        #expect(application(state, y: frame.minY, geometry: geometry, height: frame.height) == nil)
    }

    @Test @MainActor func retainedMarkerAlignmentUsesTheInsetAdjustedViewport() throws {
        let state = applicationState()
        let geometry = applicationGeometry(topInset: 20, bottomInset: 12)
        let action = try #require(application(state, y: 20, geometry: geometry))
        guard case let .retainedAlignment(_, anchorY, _) = action else {
            Issue.record("Expected retained alignment")
            return
        }
        let span = geometry.containerHeight - geometry.topInset - geometry.bottomInset - ConversationTranscriptViewportAnchor.restorationMarkerHeight
        #expect(abs(geometry.topInset + anchorY * span - 48) < 0.001)
    }

    @Test(arguments: [CGFloat(0), CGFloat(48)]) @MainActor
    func retainedApplicationSettlesAnAlreadyAlignedOrClampedNoMove(savedY: CGFloat) {
        let state = applicationState(frame: CGRect(x: 0, y: savedY, width: 300, height: 64))
        let clamped = applicationGeometry(contentHeight: 1600)
        #expect(application(state, y: savedY, geometry: clamped) == nil)
        #expect(!state.viewportAnchor.hasPendingRetainedRestoration)
        #expect(application(state, y: savedY + 20, geometry: clamped) == nil)
    }

    @Test(arguments: [CGFloat(0), -1, .nan, .infinity]) @MainActor
    func unavailableMarkerSpanCannotConsumeRetainedApplication(span: CGFloat) {
        let state = applicationState()
        let geometry = applicationGeometry(topInset: 0, bottomInset: 599 - span)
        #expect(application(state, y: 0, geometry: geometry) == nil)
        #expect(state.viewportAnchor.hasPendingRetainedRestoration)
        #expect(application(state, y: 0, geometry: applicationGeometry()) != nil)
    }

    @Test(arguments: ["gesture", "follow", "reset", "delete", "replace"]) @MainActor
    func retainedApplicationCannotReclaimALaterOwnerOrDeletedRow(reason: String) {
        let state = applicationState()
        let oldOwner = state.viewportOwnershipRevision
        let generation = state.initialScrollGeneration
        switch reason {
        case "gesture": state.observeViewportGesture(isInteracting: true)
        case "follow": state.retireViewportRestoration()
        case "reset": state.rearmAfterTranscriptEmptied()
        case "delete": state.retainViewportMessages(withIDs: [])
        default: state.retainViewportMessages(withIDs: ["replacement"])
        }
        let queued = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 0, width: 300, height: 64), divider: "seen", generation: generation, ownershipRevision: oldOwner
        )
        #expect(state.viewportAnchor.application(id: "row-31", measurement: queued, geometry: applicationGeometry(), preserve: true, entryGeneration: state.initialScrollGeneration) == nil)
        #expect(application(state, y: 0, geometry: applicationGeometry()) == nil)
    }

    @Test @MainActor func lazyDerealizationAndInvalidFramesKeepTheApplicationPending() {
        let state = applicationState()
        state.viewportAnchor.remove(id: "row-31", generation: state.initialScrollGeneration, entryGeneration: state.initialScrollGeneration, ownershipRevision: state.viewportOwnershipRevision)
        #expect(application(state, y: 0, geometry: applicationGeometry(), height: 0) == nil)
        #expect(application(state, y: .nan, geometry: applicationGeometry()) == nil)
        #expect(state.viewportAnchor.hasPendingRetainedRestoration)
        #expect(application(state, y: 0, geometry: applicationGeometry()) != nil)
    }

    @Test @MainActor func nonRetainedDividerAdjustmentKeepsItsNativeOffsetApplication() throws {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        #expect(application(state, y: 48, geometry: applicationGeometry(), divider: "old") == nil)
        let action = try #require(application(state, y: 28, geometry: applicationGeometry(), divider: "new"))
        guard case .offset(let offset) = action else {
            Issue.record("Divider changes retain their existing native correction")
            return
        }
        #expect(offset == 980)
    }

    @Test @MainActor func retainedAlignmentDiagnosticsKeepTheCommandAndLaterMeasuredFrames() {
        let state = applicationState()
        _ = application(state, y: 0, geometry: applicationGeometry())
        state.viewportAnchor.recordRestorationAlignment(anchorY: 0.1, rowY: 48, before: 1000, immediate: 1000)
        for _ in 0..<20 { #expect(application(state, y: 48, geometry: applicationGeometry()) == nil) }
        let summary = state.viewportAnchor.restorationSummary
        #expect(summary.split(separator: ";").count == 8)
        #expect(summary.hasPrefix("restore=row-31 y=48.0"))
        #expect(summary.contains("align anchor=0.1 targetY=48.0 before=1000.0 immediate=Optional(1000.0)"))
        #expect(summary.contains("after="))
        #expect(state.viewportAnchor.restorationSummary == summary)
        state.retireViewportRestoration()
        let cancelled = state.viewportAnchor.restorationSummary
        _ = application(state, y: 48, geometry: applicationGeometry())
        #expect(state.viewportAnchor.restorationSummary == cancelled)
    }

    private enum ApplicationGeometryFixture {
        static let width: CGFloat = 300
        static let rowHeight: CGFloat = 64
        static let savedY: CGFloat = 48
        static let viewportHeight: CGFloat = 600
        static let contentHeight: CGFloat = 2800
        static let offset: CGFloat = 1000
        static let distance: CGFloat = 900
        static let frame = CGRect(x: 0, y: savedY, width: width, height: rowHeight)
    }

    @MainActor private func applicationState(frame: CGRect = ApplicationGeometryFixture.frame) -> ConversationTranscriptScrollState {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: ApplicationGeometryFixture.distance)
        state.retainViewportMessages(withIDs: ["row-31"])
        _ = application(state, y: frame.minY, geometry: applicationGeometry(), height: frame.height)
        state.suspendViewport()
        #expect(state.resumeViewportTarget() == "row-31")
        state.retainedViewportScrollIssued(target: "row-31", generation: state.initialScrollGeneration, ownershipRevision: state.viewportOwnershipRevision)
        return state
    }

    private func applicationGeometry(contentHeight: CGFloat = ApplicationGeometryFixture.contentHeight, topInset: CGFloat = 0, bottomInset: CGFloat = 0) -> ConversationTranscriptScrollPolicy.ViewportGeometry {
        .init(contentOffsetY: ApplicationGeometryFixture.offset, contentHeight: contentHeight, containerHeight: ApplicationGeometryFixture.viewportHeight, topInset: topInset, bottomInset: bottomInset)
    }

    @MainActor private func application(
        _ state: ConversationTranscriptScrollState,
        y: CGFloat,
        geometry: ConversationTranscriptScrollPolicy.ViewportGeometry,
        height: CGFloat = ApplicationGeometryFixture.rowHeight,
        divider: String = "seen"
    ) -> ConversationTranscriptViewportAnchor.Application? {
        state.viewportAnchor.application(
            id: "row-31",
            measurement: .init(
                frame: CGRect(x: 0, y: y, width: ApplicationGeometryFixture.width, height: height),
                divider: divider,
                generation: state.initialScrollGeneration,
                ownershipRevision: state.viewportOwnershipRevision
            ),
            geometry: geometry,
            preserve: true,
            entryGeneration: state.initialScrollGeneration
        )
    }
}
