import Testing
@testable import Intent

struct StatusDerivationTests {
    // Helper to build a Workspace with specific fields
    private func makeWorkspace(
        prStatus: String? = nil,
        diffSummaryTotalFiles: Int? = nil,
        taskStatsTotal: Int? = nil,
        taskStatsCompleted: Int? = nil,
        taskStatsInProgress: Int? = nil
    ) -> Workspace {
        Workspace(
            id: "test", title: "Test", branch: nil, baseRef: nil,
            status: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: nil,
            repositoryName: nil, prStatus: prStatus, prNumber: nil,
            diffSummaryTotalFiles: diffSummaryTotalFiles,
            taskStatsTotal: taskStatsTotal,
            taskStatsCompleted: taskStatsCompleted,
            taskStatsInProgress: taskStatsInProgress,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    // MARK: - Status derivation

    @Test func prMergedStatus() async throws {
        let ws = makeWorkspace(prStatus: "Merged")
        #expect(deriveDisplayStatus(from: ws) == .prMerged)
    }

    @Test func prOpenStatus() async throws {
        let ws = makeWorkspace(prStatus: "Open")
        #expect(deriveDisplayStatus(from: ws) == .prOpen)
    }

    @Test func prDraftStatus() async throws {
        let ws = makeWorkspace(prStatus: "Draft")
        #expect(deriveDisplayStatus(from: ws) == .prOpen)
    }

    @Test func allTasksComplete() async throws {
        let ws = makeWorkspace(taskStatsTotal: 3, taskStatsCompleted: 3)
        #expect(deriveDisplayStatus(from: ws) == .complete)
    }

    @Test func tasksInProgress() async throws {
        let ws = makeWorkspace(taskStatsTotal: 5, taskStatsCompleted: 1, taskStatsInProgress: 2)
        #expect(deriveDisplayStatus(from: ws) == .inProgress)
    }

    @Test func someTasksCompleted() async throws {
        let ws = makeWorkspace(taskStatsTotal: 5, taskStatsCompleted: 2)
        #expect(deriveDisplayStatus(from: ws) == .inProgress)
    }

    @Test func hasDiffFilesOnly() async throws {
        let ws = makeWorkspace(diffSummaryTotalFiles: 3)
        #expect(deriveDisplayStatus(from: ws) == .inProgress)
    }

    @Test func noActivityNotStarted() async throws {
        let ws = makeWorkspace()
        #expect(deriveDisplayStatus(from: ws) == .notStarted)
    }

    // MARK: - Labels

    @Test func statusLabels() async throws {
        #expect(WorkspaceDisplayStatus.notStarted.label == "No Code Changes")
        #expect(WorkspaceDisplayStatus.inProgress.label == "In Progress")
        #expect(WorkspaceDisplayStatus.complete.label == "Complete")
        #expect(WorkspaceDisplayStatus.prOpen.label == "PR Open")
        #expect(WorkspaceDisplayStatus.prMerged.label == "PR Merged")
    }

    // MARK: - Sort order

    @Test func sortOrderOrdering() async throws {
        let ordered: [WorkspaceDisplayStatus] = [.inProgress, .prOpen, .notStarted, .complete, .prMerged]
        for i in 0..<ordered.count - 1 {
            #expect(ordered[i].sortOrder < ordered[i + 1].sortOrder)
        }
    }
}

