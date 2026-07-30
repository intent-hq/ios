import Testing
@testable import Intent

struct StatusDerivationTests {
    // Helper to build a Workspace with specific fields
    private func makeWorkspace(
        displayStatus: String? = nil,
        prStatus: String? = nil,
        diffSummaryTotalFiles: Int? = nil,
        taskStatsTotal: Int? = nil,
        taskStatsCompleted: Int? = nil,
        taskStatsInProgress: Int? = nil
    ) -> Workspace {
        Workspace(
            id: "test", title: "Test", branch: nil, baseRef: nil,
            status: nil, activity: nil, displayStatus: displayStatus,
            lastActivity: nil, updatedAt: nil, repositoryOwner: nil,
            repositoryName: nil, prStatus: prStatus, prNumber: nil,
            diffSummaryTotalFiles: diffSummaryTotalFiles,
            taskStatsTotal: taskStatsTotal,
            taskStatsCompleted: taskStatsCompleted,
            taskStatsInProgress: taskStatsInProgress,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    // MARK: - Wire value mapping

    @Test func wireValueMapping() async throws {
        #expect(WorkspaceDisplayStatus(wireValue: "not_started") == .notStarted)
        #expect(WorkspaceDisplayStatus(wireValue: "in_progress") == .inProgress)
        #expect(WorkspaceDisplayStatus(wireValue: "complete") == .complete)
        #expect(WorkspaceDisplayStatus(wireValue: "pr_ready") == .prReady)
        #expect(WorkspaceDisplayStatus(wireValue: "pr_open") == .prOpen)
        #expect(WorkspaceDisplayStatus(wireValue: "pr_merged") == .prMerged)
        #expect(WorkspaceDisplayStatus(wireValue: "some_future_status") == nil)
    }

    // MARK: - Resolution (BE-owned value only)

    @Test func resolveUsesBackendValue() async throws {
        // BE value is authoritative — local workspace fields never override it
        let ws = makeWorkspace(displayStatus: "in_progress", prStatus: "Merged")
        #expect(resolveDisplayStatus(for: ws) == .inProgress)
    }

    @Test func resolveMapsPrReady() async throws {
        let ws = makeWorkspace(displayStatus: "pr_ready", prStatus: "Open")
        #expect(resolveDisplayStatus(for: ws) == .prReady)
    }

    @Test func resolveDefaultsToNotStartedWhenFieldAbsent() async throws {
        let ws = makeWorkspace(prStatus: "Merged")
        #expect(resolveDisplayStatus(for: ws) == .notStarted)
    }

    @Test func resolveDefaultsToNotStartedOnUnknownWireValue() async throws {
        let ws = makeWorkspace(displayStatus: "some_future_status", prStatus: "Open")
        #expect(resolveDisplayStatus(for: ws) == .notStarted)
    }

    // MARK: - Labels

    @Test func statusLabels() async throws {
        #expect(WorkspaceDisplayStatus.notStarted.label == "No Code Changes")
        #expect(WorkspaceDisplayStatus.inProgress.label == "In Progress")
        #expect(WorkspaceDisplayStatus.complete.label == "Complete")
        #expect(WorkspaceDisplayStatus.prReady.label == "PR Mergeable")
        #expect(WorkspaceDisplayStatus.prOpen.label == "PR Open")
        #expect(WorkspaceDisplayStatus.prMerged.label == "PR Merged")
    }

    // MARK: - Sort order

    @Test func sortOrderOrdering() async throws {
        let ordered: [WorkspaceDisplayStatus] = [.inProgress, .prReady, .prOpen, .notStarted, .complete, .prMerged]
        for i in 0..<ordered.count - 1 {
            #expect(ordered[i].sortOrder < ordered[i + 1].sortOrder)
        }
    }
}

