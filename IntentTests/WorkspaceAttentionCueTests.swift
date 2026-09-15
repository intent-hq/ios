import Foundation
@testable import Intent
import Testing

@Suite struct WorkspaceAttentionCueTests {
    private func makeWorkspace(
        id: String,
        displayStatus: String? = nil,
        attention: String? = nil
    ) -> Workspace {
        Workspace(
            id: id,
            title: "Test",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: displayStatus,
            attention: attention,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil
        )
    }

    // MARK: - workspaceNeedsInput

    @Test func needsInput_attentionStatusesAndUnreadFlag() {
        #expect(workspaceNeedsInput(makeWorkspace(id: "1", displayStatus: "blocked")))
        #expect(workspaceNeedsInput(makeWorkspace(id: "2", displayStatus: "needs_attention")))
        #expect(workspaceNeedsInput(makeWorkspace(id: "3", attention: "unread")))
        #expect(!workspaceNeedsInput(makeWorkspace(id: "4", displayStatus: "in_progress")))
        #expect(!workspaceNeedsInput(makeWorkspace(id: "5", attention: "review_required")))
        #expect(!workspaceNeedsInput(makeWorkspace(id: "6")))
    }

    // MARK: - WorkspaceAttentionCueTracker

    @Test func tracker_emptyUniverseNeverPrimes() {
        var tracker = WorkspaceAttentionCueTracker()
        let cued = tracker.observe(universe: [], attention: [])
        #expect(cued.isEmpty)
        #expect(!tracker.primed)
    }

    @Test func tracker_firstSnapshotPrimesSilently() {
        var tracker = WorkspaceAttentionCueTracker()
        let primingCue = tracker.observe(universe: ["a", "b"], attention: ["a"])
        #expect(primingCue.isEmpty)
        #expect(tracker.primed)
        // Same set after priming: still no cue.
        let repeatCue = tracker.observe(universe: ["a", "b"], attention: ["a"])
        #expect(repeatCue.isEmpty)
    }

    @Test func tracker_newAttentionCuesOnce() {
        var tracker = WorkspaceAttentionCueTracker()
        _ = tracker.observe(universe: ["a", "b"], attention: [])
        let newCue = tracker.observe(universe: ["a", "b"], attention: ["b"])
        #expect(newCue == ["b"])
        // Persisting attention does not re-cue.
        let persistingCue = tracker.observe(universe: ["a", "b"], attention: ["b"])
        #expect(persistingCue.isEmpty)
    }

    @Test func tracker_clearedThenRaisedAgainRecues() {
        var tracker = WorkspaceAttentionCueTracker()
        _ = tracker.observe(universe: ["a"], attention: ["a"])
        let clearedCue = tracker.observe(universe: ["a"], attention: [])
        #expect(clearedCue.isEmpty)
        let raisedAgainCue = tracker.observe(universe: ["a"], attention: ["a"])
        #expect(raisedAgainCue == ["a"])
    }

    // MARK: - WorkspaceAttentionCueCenter

    @Test @MainActor func cueCenter_soundsOncePerNewAttentionBatch() {
        var sounds = 0
        let center = WorkspaceAttentionCueCenter { sounds += 1 }

        // Priming snapshot with pre-existing attention: silent.
        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"),
            makeWorkspace(id: "b")
        ])
        #expect(sounds == 0)

        // One batch with two new attention items: one sound.
        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"),
            makeWorkspace(id: "b", displayStatus: "blocked"),
            makeWorkspace(id: "c", displayStatus: "needs_attention")
        ])
        #expect(sounds == 1)

        // Unchanged snapshot (idempotent re-observation): no extra sound.
        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"),
            makeWorkspace(id: "b", displayStatus: "blocked"),
            makeWorkspace(id: "c", displayStatus: "needs_attention")
        ])
        #expect(sounds == 1)
    }

    @Test @MainActor func cueCenter_windowEmitsCue_publishesEventInsteadOfSound() {
        var sounds = 0
        let center = WorkspaceAttentionCueCenter(
            playSound: { sounds += 1 },
            windowEmitsCueSound: true
        )

        // Priming snapshot: silent, no event.
        center.observe(workspaces: [makeWorkspace(id: "a")])
        #expect(center.windowCueEvent == nil)

        // New attention: publishes a window cue event, never the global sound.
        center.observe(workspaces: [makeWorkspace(id: "a", displayStatus: "blocked")])
        let first = center.windowCueEvent
        #expect(first != nil)
        #expect(sounds == 0)

        // Idempotent re-observation: same event, no re-trigger.
        center.observe(workspaces: [makeWorkspace(id: "a", displayStatus: "blocked")])
        #expect(center.windowCueEvent == first)

        // Cleared then raised again: a fresh event id re-triggers playback.
        center.observe(workspaces: [makeWorkspace(id: "a")])
        center.observe(workspaces: [makeWorkspace(id: "a", displayStatus: "blocked")])
        #expect(center.windowCueEvent != nil)
        #expect(center.windowCueEvent != first)
        #expect(sounds == 0)
    }

    @Test @MainActor func cueCenter_globalSoundPath_neverPublishesWindowEvent() {
        var sounds = 0
        let center = WorkspaceAttentionCueCenter(
            playSound: { sounds += 1 },
            windowEmitsCueSound: false
        )
        center.observe(workspaces: [makeWorkspace(id: "a")])
        center.observe(workspaces: [makeWorkspace(id: "a", displayStatus: "blocked")])
        #expect(sounds == 1)
        #expect(center.windowCueEvent == nil)
    }

    // MARK: - Alert-chime / attention-cue dedup (visionOS double chime)

    private func makeDedupCenter(now: @escaping () -> Date)
        -> WorkspaceAttentionCueCenter {
        WorkspaceAttentionCueCenter(
            playSound: {},
            windowEmitsCueSound: true,
            now: now
        )
    }

    @Test @MainActor func cueCenter_unreadFlipAfterAlertChimeIsSilent() {
        // One agent:idle → alert chime plays, then the same completion
        // flips the workspace to unread: exactly one audible trigger.
        var nowDate = Date(timeIntervalSinceReferenceDate: 0)
        let center = makeDedupCenter { nowDate }
        center.observe(workspaces: [makeWorkspace(id: "a")])

        #expect(center.noteAlertChimeWillPlay(workspaceId: "a"))
        nowDate += 1
        center.observe(workspaces: [makeWorkspace(id: "a", attention: "unread")])
        #expect(center.windowCueEvent == nil)
    }

    @Test @MainActor func cueCenter_blockerTransitionAfterAlertChimeIsSilent() {
        // A raised blocker also emits agent:idle, so the blocked
        // transition coincides with an alert chime: one audible trigger.
        var nowDate = Date(timeIntervalSinceReferenceDate: 0)
        let center = makeDedupCenter { nowDate }
        center.observe(workspaces: [makeWorkspace(id: "a")])

        #expect(center.noteAlertChimeWillPlay(workspaceId: "a"))
        nowDate += 1
        center.observe(workspaces: [makeWorkspace(id: "a", displayStatus: "blocked")])
        #expect(center.windowCueEvent == nil)
    }

    @Test @MainActor func cueCenter_recentCueSuppressesAlertChimeSameWorkspaceOnly() {
        // Reverse arrival order: the attention flip is observed before the
        // chime — the chime is suppressed, but only for that workspace.
        var nowDate = Date(timeIntervalSinceReferenceDate: 0)
        let center = makeDedupCenter { nowDate }
        center.observe(workspaces: [makeWorkspace(id: "a"), makeWorkspace(id: "b")])

        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"),
            makeWorkspace(id: "b")
        ])
        #expect(center.windowCueEvent != nil)
        nowDate += 1
        #expect(!center.noteAlertChimeWillPlay(workspaceId: "a"))
        #expect(center.noteAlertChimeWillPlay(workspaceId: "b"))
    }

    @Test @MainActor func cueCenter_pureAttentionTransitionStillSounds() {
        // Attention raised with no coinciding alert (e.g. another
        // workspace's chime, or attention without idle) still sounds.
        var nowDate = Date(timeIntervalSinceReferenceDate: 0)
        let center = makeDedupCenter { nowDate }
        center.observe(workspaces: [makeWorkspace(id: "a"), makeWorkspace(id: "b")])

        #expect(center.noteAlertChimeWillPlay(workspaceId: "b"))
        nowDate += 1
        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"),
            makeWorkspace(id: "b")
        ])
        #expect(center.windowCueEvent != nil)
    }

    @Test @MainActor func cueCenter_dedupExpiresAfterInterval() {
        var nowDate = Date(timeIntervalSinceReferenceDate: 0)
        let center = makeDedupCenter { nowDate }
        center.observe(workspaces: [makeWorkspace(id: "a")])

        #expect(center.noteAlertChimeWillPlay(workspaceId: "a"))
        nowDate += WorkspaceAttentionCueCenter.dedupInterval + 0.1
        center.observe(workspaces: [makeWorkspace(id: "a", attention: "unread")])
        #expect(
            center.windowCueEvent != nil,
            "An attention flip past the dedup window is a distinct event"
        )
    }
}
