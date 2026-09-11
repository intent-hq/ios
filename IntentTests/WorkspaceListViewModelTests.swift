import Foundation
import Observation
import Testing
@testable import Intent

@Suite(.serialized)
struct WorkspaceListViewModelTests {

    // MARK: - Helpers

    private func makeWorkspace(
        id: String = "1", title: String = "Test", branch: String? = nil,
        status: String? = nil, displayStatus: String? = nil, lastActivity: String? = nil,
        createdAt: String? = nil, updatedAt: String? = nil,
        repositoryOwner: String? = nil, repositoryName: String? = nil,
        prStatus: String? = nil, prNumber: Int? = nil,
        diffSummaryTotalFiles: Int? = nil, taskStatsTotal: Int? = nil,
        taskStatsCompleted: Int? = nil, taskStatsInProgress: Int? = nil
    ) -> Workspace {
        Workspace(id: id, title: title, branch: branch, baseRef: nil, status: status,
                  activity: nil, displayStatus: displayStatus, lastActivity: lastActivity,
                  createdAt: createdAt, updatedAt: updatedAt, repositoryOwner: repositoryOwner,
                  repositoryName: repositoryName, prStatus: prStatus, prNumber: prNumber,
                  diffSummaryTotalFiles: diffSummaryTotalFiles, taskStatsTotal: taskStatsTotal,
                  taskStatsCompleted: taskStatsCompleted, taskStatsInProgress: taskStatsInProgress,
                  agentSummaryCount: nil, agentSummaryAgents: nil)
    }

    @MainActor
    private func setUp(_ workspaces: [Workspace]) -> WorkspaceListViewModel {
        WorkspaceStore.shared.workspaces = workspaces
        return WorkspaceListViewModel(workspaceStore: WorkspaceStore.shared)
    }

    @MainActor
    private func tearDown() {
        WorkspaceStore.shared.workspaces = []
        WorkspaceStore.shared.isLoading = false
    }

    // MARK: - Observation forwarding

    @Test @MainActor func storeChangesInvalidateObservedProperties() async {
        let vm = setUp([])
        defer { tearDown() }

        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = vm.workspaces
            } onChange: {
                continuation.resume()
            }
            WorkspaceStore.shared.workspaces = [makeWorkspace(id: "updated")]
        }

        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = vm.isLoading
            } onChange: {
                continuation.resume()
            }
            WorkspaceStore.shared.isLoading = true
        }

        #expect(vm.workspaces.map(\.id) == ["updated"])
        #expect(vm.isLoading)
    }

    // MARK: - filteredWorkspaces

    @Test @MainActor func filteredWorkspaces_returnsAll_whenSearchIsEmpty() {
        let ws = [makeWorkspace(id: "1", title: "Alpha"), makeWorkspace(id: "2", title: "Beta")]
        let vm = setUp(ws)
        defer { tearDown() }

        #expect(vm.filteredWorkspaces.count == 2)
    }

    @Test @MainActor func filteredWorkspaces_returnsAll_whenSearchIsWhitespaceOnly() {
        let ws = [makeWorkspace(id: "1", title: "Alpha"), makeWorkspace(id: "2", title: "Beta")]
        let vm = setUp(ws)
        defer { tearDown() }

        let allWorkspaceIDs = Set(vm.filteredWorkspaces.map(\.id))
        vm.searchText = " \n\t "

        #expect(!vm.hasSearchQuery)
        #expect(Set(vm.filteredWorkspaces.map(\.id)) == allWorkspaceIDs)
    }

    @Test @MainActor func filteredWorkspaces_filtersUsingTrimmedValue_whenSearchIsPadded() {
        let ws = [makeWorkspace(id: "1", title: "My Project"), makeWorkspace(id: "2", title: "Other")]
        let vm = setUp(ws)
        defer { tearDown() }

        vm.searchText = "  my proj  "

        #expect(vm.hasSearchQuery)
        #expect(vm.filteredWorkspaces.map(\.id) == ["1"])
    }

    @Test @MainActor func filteredWorkspaces_filtersByTitle_caseInsensitive() {
        let ws = [makeWorkspace(id: "1", title: "My Project"), makeWorkspace(id: "2", title: "Other")]
        let vm = setUp(ws)
        defer { tearDown() }

        vm.searchText = "my proj"
        #expect(vm.filteredWorkspaces.count == 1)
        #expect(vm.filteredWorkspaces.first?.id == "1")
    }

    @Test @MainActor func filteredWorkspaces_filtersByBranch() {
        let ws = [
            makeWorkspace(id: "1", title: "A", branch: "feature/login"),
            makeWorkspace(id: "2", title: "B", branch: "main")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        vm.searchText = "login"
        #expect(vm.filteredWorkspaces.count == 1)
        #expect(vm.filteredWorkspaces.first?.id == "1")
    }

    @Test @MainActor func filteredWorkspaces_filtersByRepoName() {
        let ws = [
            makeWorkspace(id: "1", title: "A", repositoryName: "intent"),
            makeWorkspace(id: "2", title: "B", repositoryName: "other-repo")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        vm.searchText = "intent"
        #expect(vm.filteredWorkspaces.count == 1)
        #expect(vm.filteredWorkspaces.first?.id == "1")
    }

    @Test @MainActor func filteredWorkspaces_sortsByLastActivityDescending() {
        let ws = [
            makeWorkspace(id: "1", title: "Old", lastActivity: "2026-01-01T00:00:00Z"),
            makeWorkspace(id: "2", title: "New", lastActivity: "2026-03-15T00:00:00Z"),
            makeWorkspace(id: "3", title: "Mid", lastActivity: "2026-02-01T00:00:00Z")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let ids = vm.filteredWorkspaces.map(\.id)
        #expect(ids == ["2", "3", "1"])
    }

    @Test @MainActor func filteredWorkspaces_lastActivityWinsOverCreatedAtAndUpdatedAt() {
        // "1" has the newest createdAt/updatedAt but an older lastActivity;
        // lastActivity must decide, as in the FE.
        let ws = [
            makeWorkspace(id: "1", lastActivity: "2026-01-01T00:00:00Z",
                          createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-02T00:00:00Z"),
            makeWorkspace(id: "2", lastActivity: "2026-02-01T00:00:00Z",
                          createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-02T00:00:00Z")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        #expect(vm.filteredWorkspaces.map(\.id) == ["2", "1"])
    }

    @Test @MainActor func filteredWorkspaces_fallsBackToCreatedAtThenUpdatedAt() {
        let ws = [
            makeWorkspace(id: "updatedOnly", updatedAt: "2026-03-01T00:00:00Z"),
            makeWorkspace(id: "createdOverUpdated", createdAt: "2026-02-01T00:00:00Z",
                          updatedAt: "2026-05-01T00:00:00Z"),
            makeWorkspace(id: "activity", lastActivity: "2026-01-15T00:00:00Z",
                          createdAt: "2026-04-01T00:00:00Z")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        // updatedOnly → 03-01, createdOverUpdated → 02-01 (createdAt beats
        // updatedAt), activity → 01-15 (lastActivity beats createdAt).
        #expect(vm.filteredWorkspaces.map(\.id) == ["updatedOnly", "createdOverUpdated", "activity"])
    }

    @Test @MainActor func filteredWorkspaces_missingOrUnparseableTimestampsSortLast() {
        let ws = [
            makeWorkspace(id: "none"),
            makeWorkspace(id: "garbage", lastActivity: "not-a-date", updatedAt: "also-not"),
            makeWorkspace(id: "stamped", lastActivity: "2026-01-01T00:00:00Z")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let ids = vm.filteredWorkspaces.map(\.id)
        #expect(ids.first == "stamped")
        #expect(Set(ids.dropFirst()) == ["none", "garbage"])
    }

    @Test @MainActor func filteredWorkspaces_comparesParsedTimesAcrossFractionalPrecision() {
        // As strings, "…00:00:00Z" > "…00:00:00.500Z" ('Z' > '.'); parsed, the
        // fractional stamp is later and must sort first.
        let ws = [
            makeWorkspace(id: "whole", lastActivity: "2026-01-01T00:00:00Z"),
            makeWorkspace(id: "fractional", lastActivity: "2026-01-01T00:00:00.500Z"),
            makeWorkspace(id: "earlierFractional", lastActivity: "2025-12-31T23:59:59.999Z")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        #expect(vm.filteredWorkspaces.map(\.id) == ["fractional", "whole", "earlierFractional"])
    }

    // MARK: - groupedByRepo

    @Test @MainActor func groupedByRepo_groupsByOwnerAndName() {
        let ws = [
            makeWorkspace(id: "1", title: "A", repositoryOwner: "acme", repositoryName: "app"),
            makeWorkspace(id: "2", title: "B", repositoryOwner: "acme", repositoryName: "app"),
            makeWorkspace(id: "3", title: "C", repositoryOwner: "acme", repositoryName: "lib")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let groups = vm.groupedByRepo
        #expect(groups.count == 2)
        #expect(groups[0].0 == "acme/app")
        #expect(groups[0].1.count == 2)
        #expect(groups[1].0 == "acme/lib")
    }

    @Test @MainActor func groupedByRepo_usesUnknown_whenRepoInfoMissing() {
        let ws = [makeWorkspace(id: "1", title: "NoRepo")]
        let vm = setUp(ws)
        defer { tearDown() }

        let groups = vm.groupedByRepo
        #expect(groups.count == 1)
        #expect(groups[0].0 == "Unknown")
    }

    @Test @MainActor func groupedByRepo_ordersGroupsByMostRecentMember_notAlphabetically() {
        // "zeta/late" has the single most recent workspace; "acme/app" has an
        // older one plus the oldest. Alphabetical would put acme first.
        let ws = [
            makeWorkspace(id: "a-old", lastActivity: "2026-01-01T00:00:00Z",
                          repositoryOwner: "acme", repositoryName: "app"),
            makeWorkspace(id: "z-new", lastActivity: "2026-03-01T00:00:00Z",
                          repositoryOwner: "zeta", repositoryName: "late"),
            makeWorkspace(id: "a-mid", lastActivity: "2026-02-01T00:00:00Z",
                          repositoryOwner: "acme", repositoryName: "app"),
            makeWorkspace(id: "m-none", repositoryOwner: "mid", repositoryName: "unstamped")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let groups = vm.groupedByRepo
        #expect(groups.map(\.0) == ["zeta/late", "acme/app", "mid/unstamped"])
        // Members keep the activity order inside their group.
        #expect(groups[1].1.map(\.id) == ["a-mid", "a-old"])
    }

    // MARK: - groupedByStatus

    @Test @MainActor func groupedByStatus_groupsAndSortsBySortOrder() {
        let ws = [
            makeWorkspace(id: "1", title: "PR", displayStatus: "pr_open"),
            makeWorkspace(id: "2", title: "WIP", displayStatus: "in_progress"),
            makeWorkspace(id: "3", title: "New", displayStatus: "not_started"),
            makeWorkspace(id: "4", title: "Quiet", displayStatus: "idle")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let groups = vm.groupedByStatus
        #expect(groups.count == 4)
        // Sorted by sortOrder: idle(3), notStarted(4), inProgress(5), prOpen(7)
        #expect(groups[0].0 == "Idle")
        #expect(groups[1].0 == "No Code Changes")
        #expect(groups[2].0 == "In Progress")
        #expect(groups[3].0 == "PR Open")
    }

    @Test @MainActor func groupedByStatus_putsNeedsAttentionFirst() {
        let ws = [
            makeWorkspace(id: "1", title: "Quiet", displayStatus: "idle"),
            makeWorkspace(id: "2", title: "WIP", displayStatus: "in_progress"),
            makeWorkspace(id: "3", title: "Blocked", displayStatus: "needs_attention")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let groups = vm.groupedByStatus
        #expect(groups.count == 3)
        #expect(groups[0].0 == "Needs Attention")
        #expect(groups[0].1.map(\.id) == ["3"])
        #expect(groups[1].0 == "Idle")
        #expect(groups[2].0 == "In Progress")
    }

    @Test @MainActor func groupedByStatus_usesBackendDisplayStatusExclusively() {
        let ws = [
            // BE says in_progress; local prStatus never overrides it
            makeWorkspace(id: "1", title: "Reopened", displayStatus: "in_progress", prStatus: "Merged"),
            // BE-only prReady status (sortOrder 8, after prOpen)
            makeWorkspace(id: "2", title: "Mergeable", displayStatus: "pr_ready", prStatus: "Open"),
            // No BE value — defaults to notStarted, not derived from prStatus
            makeWorkspace(id: "3", title: "Legacy", prStatus: "Open")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let groups = vm.groupedByStatus
        #expect(groups.count == 3)
        #expect(groups[0].0 == "No Code Changes")
        #expect(groups[0].1.map(\.id) == ["3"])
        #expect(groups[1].0 == "In Progress")
        #expect(groups[1].1.map(\.id) == ["1"])
        #expect(groups[2].0 == "PR Mergeable")
        #expect(groups[2].1.map(\.id) == ["2"])
    }
}

@Suite struct WorkspaceAttentionCueTests {

    private func makeWorkspace(
        id: String, displayStatus: String? = nil, attention: String? = nil
    ) -> Workspace {
        Workspace(id: id, title: "Test", branch: nil, baseRef: nil, status: nil,
                  activity: nil, displayStatus: displayStatus, attention: attention,
                  lastActivity: nil, updatedAt: nil, repositoryOwner: nil,
                  repositoryName: nil, prStatus: nil, prNumber: nil,
                  diffSummaryTotalFiles: nil, taskStatsTotal: nil,
                  taskStatsCompleted: nil, taskStatsInProgress: nil,
                  agentSummaryCount: nil, agentSummaryAgents: nil)
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
        let center = WorkspaceAttentionCueCenter(playSound: { sounds += 1 })

        // Priming snapshot with pre-existing attention: silent.
        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"), makeWorkspace(id: "b")
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
            playSound: { sounds += 1 }, windowEmitsCueSound: true)

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
            playSound: { sounds += 1 }, windowEmitsCueSound: false)
        center.observe(workspaces: [makeWorkspace(id: "a")])
        center.observe(workspaces: [makeWorkspace(id: "a", displayStatus: "blocked")])
        #expect(sounds == 1)
        #expect(center.windowCueEvent == nil)
    }

    // MARK: - Alert-chime / attention-cue dedup (visionOS double chime)

    private func makeDedupCenter(now: @escaping () -> Date)
        -> WorkspaceAttentionCueCenter {
        WorkspaceAttentionCueCenter(
            playSound: {}, windowEmitsCueSound: true, now: now)
    }

    @Test @MainActor func cueCenter_unreadFlipAfterAlertChimeIsSilent() {
        // One agent:idle → alert chime plays, then the same completion
        // flips the workspace to unread: exactly one audible trigger.
        var nowDate = Date(timeIntervalSinceReferenceDate: 0)
        let center = makeDedupCenter(now: { nowDate })
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
        let center = makeDedupCenter(now: { nowDate })
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
        let center = makeDedupCenter(now: { nowDate })
        center.observe(workspaces: [makeWorkspace(id: "a"), makeWorkspace(id: "b")])

        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"), makeWorkspace(id: "b")
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
        let center = makeDedupCenter(now: { nowDate })
        center.observe(workspaces: [makeWorkspace(id: "a"), makeWorkspace(id: "b")])

        #expect(center.noteAlertChimeWillPlay(workspaceId: "b"))
        nowDate += 1
        center.observe(workspaces: [
            makeWorkspace(id: "a", attention: "unread"), makeWorkspace(id: "b")
        ])
        #expect(center.windowCueEvent != nil)
    }

    @Test @MainActor func cueCenter_dedupExpiresAfterInterval() {
        var nowDate = Date(timeIntervalSinceReferenceDate: 0)
        let center = makeDedupCenter(now: { nowDate })
        center.observe(workspaces: [makeWorkspace(id: "a")])

        #expect(center.noteAlertChimeWillPlay(workspaceId: "a"))
        nowDate += WorkspaceAttentionCueCenter.dedupInterval + 0.1
        center.observe(workspaces: [makeWorkspace(id: "a", attention: "unread")])
        #expect(center.windowCueEvent != nil,
                "An attention flip past the dedup window is a distinct event")
    }
}

/// Duplicate windows bound to one backend all observe the same
/// FeedbackEvent/WindowCueEvent; the claim registry lets exactly one
/// window's emitter play each event.
@Suite @MainActor struct WindowSoundClaimRegistryTests {

    @Test func twoWindowsOnOneBackend_exactlyOnePlaybackPerEvent() {
        let registry = WindowSoundClaimRegistry()
        let event = UUID()
        // Both duplicate windows observe the same event id; only the
        // first observer plays.
        #expect(registry.claim(event))
        #expect(!registry.claim(event))
    }

    @Test func windowsOnDifferentBackends_unaffected() {
        let registry = WindowSoundClaimRegistry()
        // Different backends publish distinct events (fresh ids); each
        // window's claim succeeds.
        #expect(registry.claim(UUID()))
        #expect(registry.claim(UUID()))
    }

    @Test func backToBackDistinctEvents_eachPlay() {
        let registry = WindowSoundClaimRegistry()
        let first = UUID()
        let second = UUID()
        #expect(registry.claim(first))
        #expect(registry.claim(second),
                "A fresh event id is a new sound, not a duplicate")
        #expect(!registry.claim(first))
        #expect(!registry.claim(second))
    }

    @Test func evictionKeepsRecentClaims() {
        let registry = WindowSoundClaimRegistry(capacity: 2)
        let old = UUID()
        #expect(registry.claim(old))
        #expect(registry.claim(UUID()))
        #expect(registry.claim(UUID()))
        // `old` was evicted (FIFO); the bound only needs to cover ids
        // still observable within a MainActor turn of publication.
        #expect(registry.claim(old))
    }
}

