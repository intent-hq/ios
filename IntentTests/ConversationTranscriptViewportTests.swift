import Foundation
@testable import Intent
import Testing

extension ConversationTranscriptScrollPolicyTests {
    @Test func previousEntryCannotMeasureOrRemoveTheCurrentAnchor() {
        var anchor = ConversationTranscriptViewportAnchor()
        let before = CGRect(x: 0, y: 40, width: 300, height: 50)
        let current = 2
        let old = 1
        _ = anchor.record(id: "visible", measurement: .init(frame: before, divider: nil, generation: current), viewportHeight: 600, preserve: false, entryGeneration: current)
        _ = anchor.record(id: "other", measurement: .init(frame: .zero, divider: "seen", generation: current), viewportHeight: 600, preserve: true, entryGeneration: current)
        #expect(anchor.record(id: "visible", measurement: .init(frame: before.offsetBy(dx: 0, dy: 100), divider: "seen", generation: old), viewportHeight: 600, preserve: true, entryGeneration: current) == nil)
        anchor.remove(id: "visible", generation: old, entryGeneration: current)
        #expect(anchor.record(id: "visible", measurement: .init(frame: before.offsetBy(dx: 0, dy: 39), divider: "seen", generation: current), viewportHeight: 600, preserve: true, entryGeneration: current) == 39)
    }

    @Test func entryChangeAndMissingTargetRetireAnOutstandingAdjustment() {
        for missing in [false, true] {
            var anchor = ConversationTranscriptViewportAnchor()
            let before = CGRect(x: 0, y: 40, width: 300, height: 50)
            _ = anchor.record(id: "visible", measurement: .init(frame: before, divider: nil), viewportHeight: 600, preserve: false)
            _ = anchor.record(id: "other", measurement: .init(frame: .zero, divider: "seen"), viewportHeight: 600, preserve: true)
            if missing { anchor.remove(id: "visible") }
            let generation = missing ? 0 : 1
            let shifted = ConversationTranscriptViewportAnchor.Measurement(frame: before.offsetBy(dx: 0, dy: 39), divider: "seen", generation: generation)
            #expect(anchor.record(id: "visible", measurement: shifted, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
            #expect(anchor.record(id: "visible", measurement: shifted, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
        }
    }

    @Test func lateDividerPreservesAnOversizedVisibleMessage() {
        var anchor = ConversationTranscriptViewportAnchor()
        let before = CGRect(x: 0, y: -100, width: 300, height: 900)
        _ = anchor.record(id: "long-message", measurement: .init(frame: before, divider: nil), viewportHeight: 600, preserve: false)
        #expect(anchor.record(id: "long-message", measurement: .init(frame: before.offsetBy(dx: 0, dy: 39), divider: "seen"), viewportHeight: 600, preserve: true) == 39)
    }

    @Test func readyMetadataUsesNormalEntryPositioning() {
        var anchor = ConversationTranscriptViewportAnchor()
        let before = CGRect(x: 0, y: 40, width: 300, height: 50)
        _ = anchor.record(id: "visible", measurement: .init(frame: before, divider: nil), viewportHeight: 600, preserve: false)
        #expect(anchor.record(id: "visible", measurement: .init(frame: before.offsetBy(dx: 0, dy: 39), divider: "seen"), viewportHeight: 600, preserve: false) == nil)
    }

    @Test(arguments: [false, true])
    func lateDividerKeepsTheMeasuredRowOffset(otherRowArrivesFirst: Bool) {
        var anchor = ConversationTranscriptViewportAnchor()
        let height: CGFloat = 600
        for (id, y) in [("partial", CGFloat(-20)), ("visible", 61), ("next", 126)] {
            #expect(anchor.record(id: id, measurement: .init(frame: CGRect(x: 0, y: y, width: 300, height: 50), divider: nil), viewportHeight: height, preserve: false) == nil)
        }
        let other = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 165, width: 300, height: 50), divider: "earlier-row"
        )
        if otherRowArrivesFirst {
            #expect(anchor.record(id: "next", measurement: other, viewportHeight: height, preserve: true) == nil)
        }
        let shifted = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 100, width: 300, height: 50), divider: "earlier-row"
        )
        #expect(anchor.record(id: "visible", measurement: shifted, viewportHeight: height, preserve: true) == 39)
        #expect(anchor.record(id: "visible", measurement: shifted, viewportHeight: height, preserve: true) == nil,
                "one divider revision cannot keep correcting later layout or user movement")
    }

    @Test(arguments: [false, true])
    func lateDividerDoesNotDoubleCorrectBottomAnchoring(orphaned: Bool) {
        var anchor = ConversationTranscriptViewportAnchor()
        let frame = CGRect(x: 0, y: 500, width: 300, height: 50)
        _ = anchor.record(id: "last", measurement: .init(frame: frame, divider: nil), viewportHeight: 600, preserve: false)
        if orphaned { anchor.remove(id: "last") }
        #expect(anchor.record(id: "last", measurement: .init(frame: frame, divider: "seen"), viewportHeight: 600, preserve: true) == nil)
    }

    @Test(arguments: [false, true])
    func newGestureOrExplicitFollowCancelsDividerRestoration(reset: Bool) {
        var anchor = ConversationTranscriptViewportAnchor()
        let frame = CGRect(x: 0, y: 40, width: 300, height: 50)
        _ = anchor.record(id: "visible", measurement: .init(frame: frame, divider: nil), viewportHeight: 600, preserve: false)
        _ = anchor.record(id: "other", measurement: .init(frame: .zero, divider: "seen"), viewportHeight: 600, preserve: true)
        if reset { anchor = .init() } else { anchor.cancelRestoration() }
        #expect(anchor.record(id: "visible", measurement: .init(frame: frame.offsetBy(dx: 0, dy: 39), divider: "seen"), viewportHeight: 600, preserve: true) == nil)
    }

    @Test @MainActor func preservedEntryIsSettledWithoutInventingAForcedFollow() {
        let state = ConversationTranscriptScrollState()
        #expect(!state.entryViewportPreserved)
        state.preservePresentedViewport(distanceToBottom: 0)
        #expect(state.entryViewportPreserved && state.hasInitiallyScrolled)
        #expect(state.lastForcedFollowOutcome == nil && !state.hasRequestedForcedFollow)
        state.rearmAfterTranscriptEmptied()
        #expect(!state.entryViewportPreserved)
    }
}
