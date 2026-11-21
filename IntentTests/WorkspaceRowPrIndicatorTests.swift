import Foundation
@testable import Intent
import SwiftUI
import Testing

@MainActor
struct WorkspaceRowPrIndicatorTests {
    private func makeWorkspace(
        repositoryOwner: String? = "octo",
        repositoryName: String? = "repo",
        prStatus: String? = nil,
        prNumber: Int? = nil,
        pullRequests: [WorkspacePullRequest] = [],
        pullRequestsWereReported: Bool = false,
        activePullRequest: WorkspacePullRequest? = nil
    ) -> Workspace {
        Workspace(
            id: "ws-abc",
            title: "Test",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: repositoryOwner,
            repositoryName: repositoryName,
            prStatus: prStatus,
            prNumber: prNumber,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            pullRequests: pullRequests,
            pullRequestsWereReported: pullRequestsWereReported,
            activePullRequest: activePullRequest
        )
    }

    private func makeMonitor(
        repo: String = "octo/repo",
        prNumber: Int = 12,
        state: MonitoredPr.State = .active,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        snapshot: MonitoredPr.Snapshot? = nil
    ) -> MonitoredPr {
        MonitoredPr(
            monitorId: "prm-\(repo)-\(prNumber)",
            workspaceId: "ws-abc",
            agentId: "agent-1",
            repo: repo,
            prNumber: prNumber,
            state: state,
            pendingChanges: [],
            hasPendingChanges: false,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pendingSince: nil,
            lastChangeAt: nil,
            lastPolledAt: nil,
            lastError: nil,
            title: nil,
            url: nil,
            lastSnapshot: snapshot
        )
    }

    private func makePr(
        _ number: Int,
        _ status: String,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) -> WorkspacePullRequest {
        WorkspacePullRequest(
            number: number,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Pool primary chosen

    @Test func poolPrimaryIsOldestOpenAcrossPullRequestsAndMonitors() {
        let workspace = makeWorkspace(pullRequests: [
            makePr(20, "Open", createdAt: "2026-08-10T00:00:00Z"),
            makePr(30, "Merged", updatedAt: "2026-08-15T00:00:00Z")
        ])
        let monitors = [makeMonitor(prNumber: 10, createdAt: "2026-08-01T00:00:00Z")]

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 10))
        #expect(model.otherMonitorCount == 0)
    }

    @Test func poolPrimaryWinsOverLegacyFields() {
        let workspace = makeWorkspace(
            prStatus: "Merged",
            prNumber: 99,
            pullRequests: [makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z")]
        )

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == .init(status: .open, number: 12))
    }

    @Test func monitorOnlyPoolRendersMonitorPill() {
        let workspace = makeWorkspace()
        let monitors = [makeMonitor(prNumber: 7, createdAt: "2026-08-01T00:00:00Z")]

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 7))
        #expect(model.otherMonitorCount == 0)
    }

    // MARK: - activePullRequest fallback pool (FE mapWorkspacePRs parity)

    @Test func activePullRequestOnlySeedsPoolAndBeatsLegacyFields() {
        let workspace = makeWorkspace(
            prStatus: "Merged",
            prNumber: 99,
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z")
        )

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 0)
    }

    @Test func activePullRequestSeedsPoolWhenPullRequestsIsEmptyArray() {
        let workspace = makeWorkspace(
            pullRequests: [],
            pullRequestsWereReported: true,
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z")
        )

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == .init(status: .open, number: 12))
    }

    @Test func activePullRequestMergesWithMonitorsForPrimaryAndCount() {
        let workspace = makeWorkspace(
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z")
        )
        let monitors = [
            makeMonitor(prNumber: 12, createdAt: "2026-08-05T00:00:00Z"),
            makeMonitor(prNumber: 34, createdAt: "2026-08-10T00:00:00Z")
        ]

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 1)
    }

    @Test func nonEmptyPullRequestsIgnoresActivePullRequest() {
        let workspace = makeWorkspace(
            pullRequests: [makePr(20, "Open", createdAt: "2026-08-10T00:00:00Z")],
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z")
        )

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == .init(status: .open, number: 20))
    }

    // MARK: - Legacy fallback path

    @Test func emptyPoolFallsBackToLegacyPrStatusAndNumber() {
        let workspace = makeWorkspace(prStatus: "Merged", prNumber: 42)

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == .init(status: .merged, number: 42))
        #expect(model.otherMonitorCount == 0)
    }

    @Test func legacyFallbackWithoutNumberRendersNumberlessPill() {
        let workspace = makeWorkspace(prStatus: "Open")

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == .init(status: .open, number: nil))
    }

    @Test func unknownLegacyStatusRendersNoPill() {
        let workspace = makeWorkspace(prStatus: "SomethingNew", prNumber: 5)

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == nil)
        #expect(model.otherMonitorCount == 0)
    }

    @Test func nothingRendersExactlyAsToday() {
        let workspace = makeWorkspace()

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])
        #expect(model.pill == nil)
        #expect(model.otherMonitorCount == 0)
    }

    // MARK: - "+N" count

    @Test func otherMonitorsBeyondPrimaryAreCounted() {
        let workspace = makeWorkspace(pullRequests: [
            makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z")
        ])
        let monitors = [
            makeMonitor(prNumber: 12),
            makeMonitor(prNumber: 34),
            makeMonitor(repo: "other/repo", prNumber: 12)
        ]

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 2)
    }

    @Test func crossRepoPrimaryExcludesOnlyItsOwnMonitor() {
        let workspace = makeWorkspace()
        let monitors = [
            makeMonitor(
                repo: "other/repo",
                prNumber: 12,
                createdAt: "2026-08-01T00:00:00Z"
            ),
            makeMonitor(prNumber: 12, createdAt: "2026-08-10T00:00:00Z")
        ]

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 1)
    }

    @Test func completedMonitorWithMergedSnapshotRendersMergedPill() {
        let workspace = makeWorkspace()
        let snapshot = MonitoredPr.Snapshot(
            state: "merged",
            isDraft: false,
            hasConflicts: false,
            isBehind: false,
            mergeability: .computing,
            mergeBlockedReason: nil,
            checks: .init(total: 0, passed: 0, failed: 0, pending: 0),
            approvals: .init(decision: "none", have: 0, needed: nil, changesRequested: 0),
            threads: .init(unresolved: 0)
        )
        let monitors = [
            makeMonitor(
                prNumber: 8,
                state: .completed,
                updatedAt: "2026-08-14T00:00:00Z",
                snapshot: snapshot
            )
        ]

        let model = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: monitors)
        #expect(model.pill == .init(status: .merged, number: 8))
    }

    // MARK: - Legacy pill status / color mapping

    @Test func legacyPillStatusMapsOnlyKnownWireStrings() {
        #expect(WorkspaceRowView.legacyPillStatus("Merged") == .merged)
        #expect(WorkspaceRowView.legacyPillStatus("Open") == .open)
        #expect(WorkspaceRowView.legacyPillStatus("Draft") == .draft)
        #expect(WorkspaceRowView.legacyPillStatus("Closed") == .closed)
        #expect(WorkspaceRowView.legacyPillStatus("Unknown") == nil)
    }
}
