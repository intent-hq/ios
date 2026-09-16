import Foundation
@testable import Intent
import Observation
import Testing

@Suite(.serialized)
struct WorkspaceListViewModelTests {
    // MARK: - Helpers

    private func makeWorkspace(
        id: String = "1",
        title: String = "Test",
        branch: String? = nil,
        status: String? = nil,
        displayStatus: String? = nil,
        lastActivity: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        repositoryOwner: String? = nil,
        repositoryName: String? = nil,
        prStatus: String? = nil,
        prNumber: Int? = nil,
        diffSummaryTotalFiles: Int? = nil,
        taskStatsTotal: Int? = nil,
        taskStatsCompleted: Int? = nil,
        taskStatsInProgress: Int? = nil
    ) -> Workspace {
        Workspace(
            id: id,
            title: title,
            branch: branch,
            baseRef: nil,
            status: status,
            activity: nil,
            displayStatus: displayStatus,
            lastActivity: lastActivity,
            createdAt: createdAt,
            updatedAt: updatedAt,
            repositoryOwner: repositoryOwner,
            repositoryName: repositoryName,
            prStatus: prStatus,
            prNumber: prNumber,
            diffSummaryTotalFiles: diffSummaryTotalFiles,
            taskStatsTotal: taskStatsTotal,
            taskStatsCompleted: taskStatsCompleted,
            taskStatsInProgress: taskStatsInProgress,
            agentSummaryCount: nil
        )
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
        let viewModel = setUp([])
        defer { tearDown() }

        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = viewModel.workspaces
            } onChange: {
                continuation.resume()
            }
            WorkspaceStore.shared.workspaces = [makeWorkspace(id: "updated")]
        }

        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = viewModel.isLoading
            } onChange: {
                continuation.resume()
            }
            WorkspaceStore.shared.isLoading = true
        }

        #expect(viewModel.workspaces.map(\.id) == ["updated"])
        #expect(viewModel.isLoading)
    }

    // MARK: - filteredWorkspaces

    @Test func displayStatusWireValuesRemainExactAndCaseSensitive() {
        #expect(WorkspaceDisplayStatus(wireValue: "PR_OPEN") == nil)
        #expect(WorkspaceDisplayStatus(wireValue: "pr-open") == nil)
        #expect(WorkspaceDisplayStatus(wireValue: "") == nil)
    }

    @Test @MainActor func filteredWorkspaces_returnsAll_whenSearchIsEmpty() {
        let workspaces = [makeWorkspace(id: "1", title: "Alpha"), makeWorkspace(id: "2", title: "Beta")]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        #expect(viewModel.filteredWorkspaces.count == 2)
    }

    @Test @MainActor func filteredWorkspaces_returnsAll_whenSearchIsWhitespaceOnly() {
        let workspaces = [makeWorkspace(id: "1", title: "Alpha"), makeWorkspace(id: "2", title: "Beta")]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let allWorkspaceIDs = Set(viewModel.filteredWorkspaces.map(\.id))
        viewModel.searchText = " \n\t "

        #expect(!viewModel.hasSearchQuery)
        #expect(Set(viewModel.filteredWorkspaces.map(\.id)) == allWorkspaceIDs)
    }

    @Test @MainActor func filteredWorkspaces_filtersUsingTrimmedValue_whenSearchIsPadded() {
        let workspaces = [makeWorkspace(id: "1", title: "My Project"), makeWorkspace(id: "2", title: "Other")]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        viewModel.searchText = "  my proj  "

        #expect(viewModel.hasSearchQuery)
        #expect(viewModel.filteredWorkspaces.map(\.id) == ["1"])
    }

    @Test @MainActor func filteredWorkspaces_filtersByTitle_caseInsensitive() {
        let workspaces = [makeWorkspace(id: "1", title: "My Project"), makeWorkspace(id: "2", title: "Other")]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        viewModel.searchText = "my proj"
        #expect(viewModel.filteredWorkspaces.count == 1)
        #expect(viewModel.filteredWorkspaces.first?.id == "1")
    }

    @Test @MainActor func filteredWorkspaces_filtersByBranch() {
        let workspaces = [
            makeWorkspace(id: "1", title: "A", branch: "feature/login"),
            makeWorkspace(id: "2", title: "B", branch: "main")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        viewModel.searchText = "login"
        #expect(viewModel.filteredWorkspaces.count == 1)
        #expect(viewModel.filteredWorkspaces.first?.id == "1")
    }

    @Test @MainActor func filteredWorkspaces_filtersByRepoName() {
        let workspaces = [
            makeWorkspace(id: "1", title: "A", repositoryName: "intent"),
            makeWorkspace(id: "2", title: "B", repositoryName: "other-repo")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        viewModel.searchText = "intent"
        #expect(viewModel.filteredWorkspaces.count == 1)
        #expect(viewModel.filteredWorkspaces.first?.id == "1")
    }

    @Test @MainActor func filteredWorkspaces_sortsByLastActivityDescending() {
        let workspaces = [
            makeWorkspace(id: "1", title: "Old", lastActivity: "2026-01-01T00:00:00Z"),
            makeWorkspace(id: "2", title: "New", lastActivity: "2026-03-15T00:00:00Z"),
            makeWorkspace(id: "3", title: "Mid", lastActivity: "2026-02-01T00:00:00Z")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let ids = viewModel.filteredWorkspaces.map(\.id)
        #expect(ids == ["2", "3", "1"])
    }

    @Test @MainActor func filteredWorkspaces_lastActivityWinsOverCreatedAtAndUpdatedAt() {
        // "1" has the newest createdAt/updatedAt but an older lastActivity;
        // lastActivity must decide, as in the FE.
        let workspaces = [
            makeWorkspace(
                id: "1",
                lastActivity: "2026-01-01T00:00:00Z",
                createdAt: "2026-06-01T00:00:00Z",
                updatedAt: "2026-06-02T00:00:00Z"
            ),
            makeWorkspace(
                id: "2",
                lastActivity: "2026-02-01T00:00:00Z",
                createdAt: "2025-01-01T00:00:00Z",
                updatedAt: "2025-01-02T00:00:00Z"
            )
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        #expect(viewModel.filteredWorkspaces.map(\.id) == ["2", "1"])
    }

    @Test @MainActor func filteredWorkspaces_fallsBackToCreatedAtThenUpdatedAt() {
        let workspaces = [
            makeWorkspace(id: "updatedOnly", updatedAt: "2026-03-01T00:00:00Z"),
            makeWorkspace(
                id: "createdOverUpdated",
                createdAt: "2026-02-01T00:00:00Z",
                updatedAt: "2026-05-01T00:00:00Z"
            ),
            makeWorkspace(
                id: "activity",
                lastActivity: "2026-01-15T00:00:00Z",
                createdAt: "2026-04-01T00:00:00Z"
            )
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        // updatedOnly → 03-01, createdOverUpdated → 02-01 (createdAt beats
        // updatedAt), activity → 01-15 (lastActivity beats createdAt).
        #expect(viewModel.filteredWorkspaces.map(\.id) == ["updatedOnly", "createdOverUpdated", "activity"])
    }

    @Test @MainActor func filteredWorkspaces_missingOrUnparseableTimestampsSortLast() {
        let workspaces = [
            makeWorkspace(id: "none"),
            makeWorkspace(id: "garbage", lastActivity: "not-a-date", updatedAt: "also-not"),
            makeWorkspace(id: "stamped", lastActivity: "2026-01-01T00:00:00Z")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let ids = viewModel.filteredWorkspaces.map(\.id)
        #expect(ids.first == "stamped")
        #expect(Set(ids.dropFirst()) == ["none", "garbage"])
    }

    @Test @MainActor func filteredWorkspaces_comparesParsedTimesAcrossFractionalPrecision() {
        // As strings, "…00:00:00Z" > "…00:00:00.500Z" ('Z' > '.'); parsed, the
        // fractional stamp is later and must sort first.
        let workspaces = [
            makeWorkspace(id: "whole", lastActivity: "2026-01-01T00:00:00Z"),
            makeWorkspace(id: "fractional", lastActivity: "2026-01-01T00:00:00.500Z"),
            makeWorkspace(id: "earlierFractional", lastActivity: "2025-12-31T23:59:59.999Z")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        #expect(viewModel.filteredWorkspaces.map(\.id) == ["fractional", "whole", "earlierFractional"])
    }

    // MARK: - groupedByRepo

    @Test @MainActor func groupedByRepo_groupsByOwnerAndName() {
        let workspaces = [
            makeWorkspace(id: "1", title: "A", repositoryOwner: "acme", repositoryName: "app"),
            makeWorkspace(id: "2", title: "B", repositoryOwner: "acme", repositoryName: "app"),
            makeWorkspace(id: "3", title: "C", repositoryOwner: "acme", repositoryName: "lib")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let groups = viewModel.groupedByRepo
        #expect(groups.count == 2)
        #expect(groups[0].0 == "acme/app")
        #expect(groups[0].1.count == 2)
        #expect(groups[1].0 == "acme/lib")
    }

    @Test @MainActor func groupedByRepo_usesUnknown_whenRepoInfoMissing() {
        let workspaces = [makeWorkspace(id: "1", title: "NoRepo")]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let groups = viewModel.groupedByRepo
        #expect(groups.count == 1)
        #expect(groups[0].0 == "Unknown")
    }

    @Test @MainActor func groupedByRepo_ordersGroupsByMostRecentMember_notAlphabetically() {
        // "zeta/late" has the single most recent workspace; "acme/app" has an
        // older one plus the oldest. Alphabetical would put acme first.
        let workspaces = [
            makeWorkspace(
                id: "a-old",
                lastActivity: "2026-01-01T00:00:00Z",
                repositoryOwner: "acme",
                repositoryName: "app"
            ),
            makeWorkspace(
                id: "z-new",
                lastActivity: "2026-03-01T00:00:00Z",
                repositoryOwner: "zeta",
                repositoryName: "late"
            ),
            makeWorkspace(
                id: "a-mid",
                lastActivity: "2026-02-01T00:00:00Z",
                repositoryOwner: "acme",
                repositoryName: "app"
            ),
            makeWorkspace(id: "m-none", repositoryOwner: "mid", repositoryName: "unstamped")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let groups = viewModel.groupedByRepo
        #expect(groups.map(\.0) == ["zeta/late", "acme/app", "mid/unstamped"])
        // Members keep the activity order inside their group.
        #expect(groups[1].1.map(\.id) == ["a-mid", "a-old"])
    }

    // MARK: - groupedByStatus

    @Test @MainActor func groupedByStatus_groupsAndSortsBySortOrder() {
        let workspaces = [
            makeWorkspace(id: "1", title: "PR", displayStatus: "pr_open"),
            makeWorkspace(id: "2", title: "WIP", displayStatus: "in_progress"),
            makeWorkspace(id: "3", title: "New", displayStatus: "not_started"),
            makeWorkspace(id: "4", title: "Quiet", displayStatus: "idle")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let groups = viewModel.groupedByStatus
        #expect(groups.count == 4)
        // Sorted by sortOrder: idle(3), notStarted(4), inProgress(5), prOpen(7)
        #expect(groups[0].0 == "Idle")
        #expect(groups[1].0 == "No Code Changes")
        #expect(groups[2].0 == "In Progress")
        #expect(groups[3].0 == "PR Open")
    }

    @Test @MainActor func groupedByStatus_putsNeedsAttentionFirst() {
        let workspaces = [
            makeWorkspace(id: "1", title: "Quiet", displayStatus: "idle"),
            makeWorkspace(id: "2", title: "WIP", displayStatus: "in_progress"),
            makeWorkspace(id: "3", title: "Blocked", displayStatus: "needs_attention")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let groups = viewModel.groupedByStatus
        #expect(groups.count == 3)
        #expect(groups[0].0 == "Needs Attention")
        #expect(groups[0].1.map(\.id) == ["3"])
        #expect(groups[1].0 == "Idle")
        #expect(groups[2].0 == "In Progress")
    }

    @Test @MainActor func groupedByStatus_usesBackendDisplayStatusExclusively() {
        let workspaces = [
            // BE says in_progress; local prStatus never overrides it
            makeWorkspace(id: "1", title: "Reopened", displayStatus: "in_progress", prStatus: "Merged"),
            // BE-only prReady status (sortOrder 8, after prOpen)
            makeWorkspace(id: "2", title: "Mergeable", displayStatus: "pr_ready", prStatus: "Open"),
            // No BE value — defaults to notStarted, not derived from prStatus
            makeWorkspace(id: "3", title: "Legacy", prStatus: "Open")
        ]
        let viewModel = setUp(workspaces)
        defer { tearDown() }

        let groups = viewModel.groupedByStatus
        #expect(groups.count == 3)
        #expect(groups[0].0 == "No Code Changes")
        #expect(groups[0].1.map(\.id) == ["3"])
        #expect(groups[1].0 == "In Progress")
        #expect(groups[1].1.map(\.id) == ["1"])
        #expect(groups[2].0 == "PR Mergeable")
        #expect(groups[2].1.map(\.id) == ["2"])
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
        #expect(
            registry.claim(second),
            "A fresh event id is a new sound, not a duplicate"
        )
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
