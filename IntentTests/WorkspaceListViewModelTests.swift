import Testing
@testable import Intent

@Suite(.serialized)
struct WorkspaceListViewModelTests {

    // MARK: - Helpers

    private func makeWorkspace(
        id: String = "1", title: String = "Test", branch: String? = nil,
        status: String? = nil, displayStatus: String? = nil, lastActivity: String? = nil,
        repositoryOwner: String? = nil, repositoryName: String? = nil,
        prStatus: String? = nil, prNumber: Int? = nil,
        diffSummaryTotalFiles: Int? = nil, taskStatsTotal: Int? = nil,
        taskStatsCompleted: Int? = nil, taskStatsInProgress: Int? = nil
    ) -> Workspace {
        Workspace(id: id, title: title, branch: branch, baseRef: nil, status: status,
                  activity: nil, displayStatus: displayStatus, lastActivity: lastActivity,
                  updatedAt: nil, repositoryOwner: repositoryOwner,
                  repositoryName: repositoryName, prStatus: prStatus, prNumber: prNumber,
                  diffSummaryTotalFiles: diffSummaryTotalFiles, taskStatsTotal: taskStatsTotal,
                  taskStatsCompleted: taskStatsCompleted, taskStatsInProgress: taskStatsInProgress,
                  agentSummaryCount: nil, agentSummaryAgents: nil)
    }

    @MainActor
    private func setUp(_ workspaces: [Workspace]) -> WorkspaceListViewModel {
        WorkspaceStore.shared.workspaces = workspaces
        return WorkspaceListViewModel()
    }

    @MainActor
    private func tearDown() {
        WorkspaceStore.shared.workspaces = []
    }

    // MARK: - filteredWorkspaces

    @Test @MainActor func filteredWorkspaces_returnsAll_whenSearchIsEmpty() {
        let ws = [makeWorkspace(id: "1", title: "Alpha"), makeWorkspace(id: "2", title: "Beta")]
        let vm = setUp(ws)
        defer { tearDown() }

        #expect(vm.filteredWorkspaces.count == 2)
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
        // Sorted by sortOrder: idle(0), inProgress(1), prOpen(3), notStarted(4)
        #expect(groups[0].0 == "Idle")
        #expect(groups[1].0 == "In Progress")
        #expect(groups[2].0 == "PR Open")
        #expect(groups[3].0 == "No Code Changes")
    }

    @Test @MainActor func groupedByStatus_usesBackendDisplayStatusExclusively() {
        let ws = [
            // BE says in_progress; local prStatus never overrides it
            makeWorkspace(id: "1", title: "Reopened", displayStatus: "in_progress", prStatus: "Merged"),
            // BE-only prReady status (sortOrder 2, between inProgress and prOpen)
            makeWorkspace(id: "2", title: "Mergeable", displayStatus: "pr_ready", prStatus: "Open"),
            // No BE value — defaults to notStarted, not derived from prStatus
            makeWorkspace(id: "3", title: "Legacy", prStatus: "Open")
        ]
        let vm = setUp(ws)
        defer { tearDown() }

        let groups = vm.groupedByStatus
        #expect(groups.count == 3)
        #expect(groups[0].0 == "In Progress")
        #expect(groups[0].1.map(\.id) == ["1"])
        #expect(groups[1].0 == "PR Mergeable")
        #expect(groups[1].1.map(\.id) == ["2"])
        #expect(groups[2].0 == "No Code Changes")
        #expect(groups[2].1.map(\.id) == ["3"])
    }
}

