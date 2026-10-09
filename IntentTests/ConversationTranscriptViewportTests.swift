import CoreGraphics
import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

extension ConversationTranscriptScrollPolicyTests {
    @Test @MainActor func readyEntryAlignsOnlyItsRealizedDividerAndRejectsLateOwnership() {
        let state = ConversationTranscriptScrollState()
        state.pendingEntryDivider = "seen"
        let offscreen = ConversationTranscriptViewportAnchor.Measurement(frame: CGRect(x: 0, y: 900, width: 300, height: 30), divider: "seen")
        #expect(state.entryDividerAdjustment(offscreen, viewportHeight: 600) == nil)
        let realized = ConversationTranscriptViewportAnchor.Measurement(frame: CGRect(x: 0, y: 550, width: 300, height: 30), divider: "seen")
        #expect(state.entryDividerAdjustment(realized, viewportHeight: 600) == 550)
        #expect(state.entryDividerAdjustment(realized, viewportHeight: 600) == nil)
        state.pendingEntryDivider = "seen"
        state.retireViewportRestoration()
        #expect(state.entryDividerAdjustment(realized, viewportHeight: 600) == nil)
        state.pendingEntryDivider = "seen"
        state.observeViewportGesture(isInteracting: true)
        let afterGesture = ConversationTranscriptViewportAnchor.Measurement(frame: realized.frame, divider: "seen", ownershipRevision: state.viewportOwnershipRevision)
        #expect(state.entryDividerAdjustment(afterGesture, viewportHeight: 600) == nil)
    }

    @Test @MainActor func retainedViewportRestoresTheSameRowOffsetOnlyOnce() {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        let generation = state.initialScrollGeneration
        let revision = state.viewportOwnershipRevision
        _ = state.viewportAnchor.record(
            id: "row-31",
            measurement: .init(frame: CGRect(x: 0, y: 48, width: 300, height: 64), divider: "seen", generation: generation, ownershipRevision: revision),
            viewportHeight: 600,
            preserve: true,
            entryGeneration: generation
        )
        state.suspendViewport()
        #expect(state.hasInitiallyScrolled && state.entryViewportPreserved)
        let covered = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 900, width: 300, height: 64), divider: "seen", generation: generation, ownershipRevision: state.viewportOwnershipRevision
        )
        #expect(state.resumeViewportTarget() == "row-31")
        state.retainedViewportScrollIssued(target: "row-31", generation: state.initialScrollGeneration, ownershipRevision: state.viewportOwnershipRevision)
        #expect(state.resumeViewportTarget() == nil)
        #expect(state.viewportAnchor.record(id: "row-31", measurement: covered, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
        let offscreen = ConversationTranscriptViewportAnchor.Measurement(frame: covered.frame, divider: "new-seen", generation: generation, ownershipRevision: state.viewportOwnershipRevision)
        #expect(state.viewportAnchor.record(id: "row-31", measurement: offscreen, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
        let rehosted = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 0, width: 300, height: 64), divider: "new-seen", generation: generation, ownershipRevision: state.viewportOwnershipRevision
        )
        #expect(state.viewportAnchor.record(id: "row-31", measurement: rehosted, viewportHeight: 600, preserve: true, entryGeneration: generation) == -48)
        #expect(state.viewportAnchor.record(id: "row-31", measurement: rehosted, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
    }

    @Test(arguments: [
        (CGRect(x: 0, y: 48, width: 300, height: 0), CGFloat(600)),
        (CGRect(x: 0, y: 48, width: 0, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: 48, width: -300, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: 48, width: 300, height: -64), CGFloat(600)),
        (CGRect(x: CGFloat.nan, y: 48, width: 300, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: CGFloat.nan, width: 300, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: 48, width: CGFloat.nan, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: 48, width: 300, height: CGFloat.nan), CGFloat(600)),
        (CGRect(x: CGFloat.infinity, y: 48, width: 300, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: CGFloat.infinity, width: 300, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: 48, width: CGFloat.infinity, height: 64), CGFloat(600)),
        (CGRect(x: 0, y: 48, width: 300, height: CGFloat.infinity), CGFloat(600)),
        (CGRect.null, CGFloat(600)), (CGRect.infinite, CGFloat(600)),
        (CGRect(x: 0, y: 48, width: 300, height: 64), CGFloat(0)),
        (CGRect(x: 0, y: 48, width: 300, height: 64), CGFloat(-1)),
        (CGRect(x: 0, y: 48, width: 300, height: 64), CGFloat.nan),
        (CGRect(x: 0, y: 48, width: 300, height: 64), CGFloat.infinity)
    ]) @MainActor
    func retainedViewportWaitsForValidGeometry(frame: CGRect, viewportHeight: CGFloat) {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        let generation = state.initialScrollGeneration
        _ = state.viewportAnchor.record(
            id: "row-31",
            measurement: .init(frame: CGRect(x: 0, y: 48, width: 300, height: 64), divider: "seen", generation: generation),
            viewportHeight: 600,
            preserve: true,
            entryGeneration: generation
        )
        state.suspendViewport()
        #expect(state.resumeViewportTarget() == "row-31")
        state.retainedViewportScrollIssued(target: "row-31", generation: state.initialScrollGeneration, ownershipRevision: state.viewportOwnershipRevision)
        let revision = state.viewportOwnershipRevision
        let unrealized = ConversationTranscriptViewportAnchor.Measurement(frame: frame, divider: "seen", generation: generation, ownershipRevision: revision)
        #expect(state.viewportAnchor.record(id: "row-31", measurement: unrealized, viewportHeight: viewportHeight, preserve: true, entryGeneration: generation) == nil)
        let realized = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 0, width: 300, height: 64), divider: "seen", generation: generation, ownershipRevision: revision
        )
        #expect(state.viewportAnchor.record(id: "row-31", measurement: realized, viewportHeight: 600, preserve: true, entryGeneration: generation) == -48)
        #expect(state.viewportAnchor.record(id: "row-31", measurement: realized, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
    }

    @Test(arguments: [
        CGRect(x: 0, y: -170, width: 300, height: 900),
        CGRect(x: 0, y: 560, width: 300, height: 64)
    ]) @MainActor
    func retainedViewportRestoresIntersectingRows(frame: CGRect) {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        let generation = state.initialScrollGeneration
        _ = state.viewportAnchor.record(
            id: "row-31",
            measurement: .init(frame: CGRect(x: 0, y: 48, width: 300, height: frame.height), divider: "seen", generation: generation),
            viewportHeight: 600,
            preserve: true,
            entryGeneration: generation
        )
        state.suspendViewport()
        #expect(state.resumeViewportTarget() == "row-31")
        state.retainedViewportScrollIssued(target: "row-31", generation: state.initialScrollGeneration, ownershipRevision: state.viewportOwnershipRevision)
        let realized = ConversationTranscriptViewportAnchor.Measurement(
            frame: frame, divider: "new-seen", generation: generation, ownershipRevision: state.viewportOwnershipRevision
        )
        // An intersecting row can remain away from zero when content bounds
        // clamp the requested top alignment. Its measured offset still wins.
        let geometry = ConversationTranscriptScrollPolicy.ViewportGeometry(
            contentOffsetY: frame.minY < 0 ? 0 : 600, contentHeight: 1200, containerHeight: 600, topInset: 0, bottomInset: 0
        )
        #expect(state.viewportAnchor.record(id: "row-31", measurement: realized, viewportHeight: 600, preserve: true, entryGeneration: generation, scrollGeometry: geometry) == frame.minY - 48)
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func retainedViewportCannotOverrideALaterGestureOrFollow(gesture: Bool, prepared: Bool) {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        _ = state.viewportAnchor.record(
            id: "row-31",
            measurement: .init(frame: CGRect(x: 0, y: 48, width: 300, height: 64), divider: "seen", generation: state.initialScrollGeneration),
            viewportHeight: 600,
            preserve: true,
            entryGeneration: state.initialScrollGeneration
        )
        state.suspendViewport()
        if prepared { #expect(state.resumeViewportTarget() == "row-31") }
        let revision = state.viewportOwnershipRevision
        if gesture { state.observeViewportGesture(isInteracting: true) } else { state.retireViewportRestoration() }
        #expect(state.resumeViewportTarget() == nil)
        let queued = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 0, width: 300, height: 64), divider: "seen", generation: state.initialScrollGeneration, ownershipRevision: revision
        )
        #expect(state.viewportAnchor.record(id: "row-31", measurement: queued, viewportHeight: 600, preserve: true, entryGeneration: state.initialScrollGeneration) == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func retainedViewportSurvivesRealizationBeforeTheCoarseScroll(derealizes: Bool) {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        let generation = state.initialScrollGeneration
        let savedY = CGFloat(34.33333333333309)
        _ = state.viewportAnchor.record(
            id: "row-31",
            measurement: .init(frame: CGRect(x: 0, y: savedY, width: 300, height: 64), divider: "seen", generation: generation),
            viewportHeight: 624,
            preserve: true,
            entryGeneration: generation
        )
        state.suspendViewport()
        #expect(state.resumeViewportTarget() == "row-31")
        let revision = state.viewportOwnershipRevision
        if derealizes {
            // A lazy row leaving the host is not removal from the transcript.
            state.viewportAnchor.remove(id: "row-31", generation: generation, entryGeneration: generation, ownershipRevision: revision)
        } else {
            // Rehosting can measure the retained offset before scrollTo moves
            // the target to the top; this is not confirmation of that move.
            let beforeScroll = ConversationTranscriptViewportAnchor.Measurement(
                frame: CGRect(x: 0, y: savedY, width: 300, height: 64), divider: "seen", generation: generation, ownershipRevision: revision
            )
            #expect(state.viewportAnchor.record(id: "row-31", measurement: beforeScroll, viewportHeight: 624, preserve: true, entryGeneration: generation) == nil)
        }
        state.retainedViewportScrollIssued(target: "row-31", generation: generation, ownershipRevision: revision)
        let afterScroll = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 0, width: 300, height: 64), divider: "seen", generation: generation, ownershipRevision: state.viewportOwnershipRevision
        )
        #expect(state.viewportAnchor.record(id: "row-31", measurement: afterScroll, viewportHeight: 624, preserve: true, entryGeneration: generation) == -savedY)
        #expect(state.viewportAnchor.record(id: "row-31", measurement: afterScroll, viewportHeight: 624, preserve: true, entryGeneration: generation) == nil)
    }

    @Test @MainActor func retainedViewportKeepsThePartiallyVisibleRowAboveItsAnchor() {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 900)
        let generation = state.initialScrollGeneration
        for (id, minY) in [("partial", CGFloat(-3)), ("full", CGFloat(69))] {
            let measurement = ConversationTranscriptViewportAnchor.Measurement(frame: CGRect(x: 0, y: minY, width: 300, height: 60), divider: "seen", generation: generation)
            _ = state.viewportAnchor.record(id: id, measurement: measurement, viewportHeight: 600, preserve: true, entryGeneration: generation)
        }
        state.suspendViewport()
        #expect(state.resumeViewportTarget() == "full")
        state.retainedViewportScrollIssued(target: "full", generation: generation, ownershipRevision: state.viewportOwnershipRevision)
        let realized = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 0, width: 300, height: 60), divider: "seen", generation: generation, ownershipRevision: state.viewportOwnershipRevision
        )
        let adjustment = state.viewportAnchor.record(id: "full", measurement: realized, viewportHeight: 600, preserve: true, entryGeneration: generation)
        #expect(adjustment == -69, "Restoring the full row's offset also keeps the preceding partial row at -3")
        state.rearmAfterTranscriptEmptied()
        #expect(state.resumeViewportTarget() == nil)
    }

    @Test @MainActor func automaticFollowCompletionPublishesViewportSettlement() {
        let state = ConversationTranscriptScrollState()
        applyViewportEvent(.endRealized(userIsScrolledAway: false), to: state)
        applyViewportEvent(.viewAppeared, to: state)
        applyViewportEvent(.followRequested(forced: false), to: state)
        guard case .follow(let token, forced: false) = state.lifecycle.owner else {
            Issue.record("automatic follow did not take ownership")
            return
        }
        let changes = observeFollowing(state)
        applyViewportEvent(.followFinished(token, .executed(nil)), to: state)
        #expect(!state.isFollowing)
        #expect(changes() == 1, "the demo report must update even when no forced-follow flag changes")
        #expect(!state.hasRequestedForcedFollow && state.lastForcedFollowOutcome == nil)
    }

    @Test @MainActor func recoveryTerminalKeepsTheActualFollowActiveUntilItsOwnCompletion() throws {
        let state = ConversationTranscriptScrollState()
        applyViewportEvent(.viewAppeared, to: state)
        applyViewportEvent(.endDerealized, to: state)
        let recovery = try #require(state.lifecycle.currentRecovery)
        applyViewportEvent(.recoveryStep(recovery, .recover(pageOffsetY: 100)), to: state)
        applyViewportEvent(.followRequested(forced: false), to: state)
        guard case .follow(let token, _) = state.lifecycle.owner else {
            Issue.record("follow did not take ownership from recovery")
            return
        }
        let changes = observeFollowing(state)
        applyViewportEvent(.endRealized(userIsScrolledAway: false), to: state)
        applyViewportEvent(.recoveryFinished(recovery, .notNeeded, corrections: 1), to: state)
        #expect(state.lifecycle.currentRecovery == nil)
        #expect(state.isFollowing, "a recovered end row does not finish another viewport owner")
        #expect(changes() == 0)
        applyViewportEvent(.followFinished(token, .executed(nil)), to: state)
        #expect(!state.isFollowing)
        #expect(changes() == 1)
    }

    @Test @MainActor func staleFollowCompletionDoesNotPublishFalseSettlement() {
        let state = ConversationTranscriptScrollState()
        applyViewportEvent(.viewAppeared, to: state)
        applyViewportEvent(.followRequested(forced: false), to: state)
        guard case .follow(let old, _) = state.lifecycle.owner else {
            Issue.record("missing first owner")
            return
        }
        let changes = observeFollowing(state)
        applyViewportEvent(.followRequested(forced: false), to: state)
        applyViewportEvent(.followFinished(old, .dropped), to: state)
        #expect(state.isFollowing)
        #expect(changes() == 0, "replacement and stale completion cannot announce idle")
        applyViewportEvent(.followCancelledByGesture, to: state)
        #expect(!state.isFollowing)
        #expect(changes() == 1)
    }

    @Test @MainActor func recoveryOwnershipAndExplicitTapRemainObservable() throws {
        let state = ConversationTranscriptScrollState()
        applyViewportEvent(.viewAppeared, to: state)
        applyViewportEvent(.endDerealized, to: state)
        let recovery = try #require(state.lifecycle.currentRecovery)
        #expect(!state.isFollowing, "a polling recovery has not taken the viewport")
        let acquired = observeFollowing(state)
        applyViewportEvent(.recoveryStep(recovery, .followToEnd), to: state)
        #expect(state.isFollowing)
        #expect(acquired() == 1)
        let released = observeFollowing(state)
        applyViewportEvent(.viewDisappeared, to: state)
        #expect(!state.isFollowing)
        #expect(released() == 1)
        applyViewportEvent(.viewAppeared, to: state)
        state.isScrollingToBottom = true
        #expect(state.isFollowing, "the explicit tap owns the gap before its request")
        let tapReleased = observeFollowing(state)
        state.isScrollingToBottom = false
        #expect(!state.isFollowing)
        #expect(tapReleased() == 1)
    }

    @Test @MainActor func disappearancePublishesFollowSettlementAndRejectsItsLateCompletion() {
        let state = ConversationTranscriptScrollState()
        applyViewportEvent(.endRealized(userIsScrolledAway: false), to: state)
        applyViewportEvent(.viewAppeared, to: state)
        applyViewportEvent(.followRequested(forced: false), to: state)
        guard case .follow(let token, _) = state.lifecycle.owner else {
            Issue.record("missing follow owner")
            return
        }
        let changes = observeFollowing(state)
        applyViewportEvent(.viewDisappeared, to: state)
        #expect(!state.isFollowing)
        #expect(changes() == 1)
        applyViewportEvent(.followFinished(token, .executed(nil)), to: state)
        applyViewportEvent(.endDerealized, to: state)
        #expect(!state.lifecycle.isVisible)
        #expect(state.lifecycle.currentRecovery == nil)
        #expect(!state.isFollowing)
    }

    @MainActor private func observeFollowing(_ state: ConversationTranscriptScrollState) -> @Sendable () -> Int {
        let changes = Mutex(0)
        withObservationTracking { _ = state.isFollowing } onChange: {
            changes.withLock { $0 += 1 }
        }
        return { changes.withLock { $0 } }
    }

    @MainActor private func applyViewportEvent(
        _ event: ConversationTranscriptRecoveryLifecycle.Event, to state: ConversationTranscriptScrollState
    ) {
        // The view stores this exact reducer result before executing its effects.
        state.lifecycle = ConversationTranscriptRecoveryLifecycle.transition(state.lifecycle, event).state
    }

    @Test func queuedDividerMeasurementCannotReclaimViewportAfterCancellation() {
        var anchor = ConversationTranscriptViewportAnchor()
        let before = CGRect(x: 0, y: 61, width: 300, height: 50)
        _ = anchor.record(id: "visible", measurement: .init(frame: before, divider: nil), viewportHeight: 600, preserve: false)
        let queued = ConversationTranscriptViewportAnchor.Measurement(frame: before.offsetBy(dx: 0, dy: 39), divider: "seen")
        anchor.cancelRestoration()
        #expect(anchor.record(id: "visible", measurement: queued, viewportHeight: 600, preserve: true) == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func viewportClaimAfterEntryRejectsOldMeasurementsAndAllowsLaterMetadata(gesture: Bool) {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 500)
        let generation = state.initialScrollGeneration
        let oldRevision = state.viewportOwnershipRevision
        let before = CGRect(x: 0, y: 61, width: 300, height: 50)
        _ = state.viewportAnchor.record(
            id: "visible",
            measurement: .init(frame: before, divider: nil, generation: generation),
            viewportHeight: 600,
            preserve: true,
            entryGeneration: generation
        )
        let queued = ConversationTranscriptViewportAnchor.Measurement(
            frame: before.offsetBy(dx: 0, dy: 39), divider: "seen", generation: generation, ownershipRevision: oldRevision
        )
        if gesture {
            // The view uses these calls even after initial entry has completed.
            state.observeViewportGesture(isInteracting: true)
            state.preservePresentedViewport(distanceToBottom: 900)
            state.observeViewportGesture(isInteracting: false)
        } else {
            // Both an explicit follow claim and disappearance retire ownership.
            state.retireViewportRestoration()
        }
        #expect(state.initialScrollGeneration == generation)
        #expect(state.viewportOwnershipRevision == oldRevision + 1)
        #expect(state.viewportAnchor.record(id: "visible", measurement: queued, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)

        let currentRevision = state.viewportOwnershipRevision
        let currentFrame = before.offsetBy(dx: 0, dy: 100)
        _ = state.viewportAnchor.record(
            id: "visible",
            measurement: .init(frame: currentFrame, divider: nil, generation: generation, ownershipRevision: currentRevision),
            viewportHeight: 600,
            preserve: true,
            entryGeneration: generation
        )
        #expect(state.viewportAnchor.record(id: "visible", measurement: queued, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
        state.viewportAnchor.remove(id: "visible", generation: generation, entryGeneration: generation, ownershipRevision: oldRevision)
        let laterMetadata = ConversationTranscriptViewportAnchor.Measurement(
            frame: currentFrame.offsetBy(dx: 0, dy: 39), divider: "seen", generation: generation, ownershipRevision: currentRevision
        )
        #expect(state.viewportAnchor.record(id: "visible", measurement: laterMetadata, viewportHeight: 600, preserve: true, entryGeneration: generation) == 39)
        #expect(state.viewportAnchor.record(id: "visible", measurement: laterMetadata, viewportHeight: 600, preserve: true, entryGeneration: generation) == nil)
    }

    @Test @MainActor func viewportOwnershipChangesOncePerGestureAndRetiresOnReset() {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 500)
        let generation = state.initialScrollGeneration
        state.observeViewportGesture(isInteracting: true)
        let firstGesture = state.viewportOwnershipRevision
        state.observeViewportGesture(isInteracting: true)
        state.observeViewportGesture(isInteracting: false)
        #expect(state.viewportOwnershipRevision == firstGesture)
        state.observeViewportGesture(isInteracting: true)
        #expect(state.viewportOwnershipRevision == firstGesture + 1)
        let beforeReset = ConversationTranscriptViewportAnchor.Measurement(
            frame: CGRect(x: 0, y: 61, width: 300, height: 50),
            divider: nil,
            generation: generation,
            ownershipRevision: state.viewportOwnershipRevision
        )
        state.rearmAfterTranscriptEmptied()
        #expect(state.initialScrollGeneration == generation + 1)
        #expect(state.viewportOwnershipRevision == firstGesture + 2)
        #expect(state.viewportAnchor.record(id: "visible", measurement: beforeReset, viewportHeight: 600, preserve: true, entryGeneration: state.initialScrollGeneration) == nil)
        state.observeViewportGesture(isInteracting: true)
        #expect(state.viewportOwnershipRevision == firstGesture + 3, "reset also retires the previous gesture latch")
    }

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
