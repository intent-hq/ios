import Foundation
import SwiftUI
import Testing
@testable import Intent

/// View-model-level tests for `WorkspaceRowView.derivePrIndicator` (the pure
/// static composition of pullRequests + monitors → pill/"+N"; the SwiftUI
/// body itself is not under test), mirroring MonitoredPrsRowTests style.
@MainActor
struct WorkspaceRowPrIndicatorTests {

    private func makeWorkspace(
        repositoryOwner: String? = "octo",
        repositoryName: String? = "repo",
        prStatus: String? = nil,
        prNumber: Int? = nil,
        pullRequests: [WorkspacePullRequest]? = nil,
        activePullRequest: WorkspacePullRequest? = nil
    ) -> Workspace {
        Workspace(
            id: "ws-abc", title: "Test", branch: nil, baseRef: nil,
            status: nil, activity: nil, displayStatus: nil,
            lastActivity: nil, updatedAt: nil,
            repositoryOwner: repositoryOwner, repositoryName: repositoryName,
            prStatus: prStatus, prNumber: prNumber,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil, taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil,
            pullRequests: pullRequests,
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
            monitorId: "prm-\(repo)-\(prNumber)", workspaceId: "ws-abc",
            agentId: "agent-1", repo: repo, prNumber: prNumber, state: state,
            pendingChanges: [], hasPendingChanges: false,
            createdAt: createdAt, updatedAt: updatedAt, pendingSince: nil,
            lastChangeAt: nil, lastPolledAt: nil, lastError: nil,
            title: nil, url: nil, lastSnapshot: snapshot
        )
    }

    private func makePr(_ number: Int, _ status: String,
                        createdAt: String? = nil,
                        updatedAt: String? = nil) -> WorkspacePullRequest {
        WorkspacePullRequest(number: number, status: status,
                             createdAt: createdAt, updatedAt: updatedAt)
    }

    // MARK: - Pool primary chosen

    @Test func poolPrimaryIsOldestOpenAcrossPullRequestsAndMonitors() {
        let ws = makeWorkspace(pullRequests: [
            makePr(20, "Open", createdAt: "2026-08-10T00:00:00Z"),
            makePr(30, "Merged", updatedAt: "2026-08-15T00:00:00Z"),
        ])
        let monitors = [makeMonitor(prNumber: 10, createdAt: "2026-08-01T00:00:00Z")]

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 10))
        #expect(model.otherMonitorCount == 0)
    }

    @Test func poolPrimaryWinsOverLegacyFields() {
        // Legacy prStatus/prNumber must not override a non-empty pool.
        let ws = makeWorkspace(
            prStatus: "Merged", prNumber: 99,
            pullRequests: [makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z")])

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == .init(status: .open, number: 12))
    }

    @Test func monitorOnlyPoolRendersMonitorPill() {
        let ws = makeWorkspace()
        let monitors = [makeMonitor(prNumber: 7, createdAt: "2026-08-01T00:00:00Z")]

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 7))
        #expect(model.otherMonitorCount == 0)
    }

    // MARK: - activePullRequest fallback pool (FE mapWorkspacePRs parity)

    @Test func activePullRequestOnlySeedsPoolAndBeatsLegacyFields() {
        // Status comes from the active PR row, not the legacy fields.
        let ws = makeWorkspace(
            prStatus: "Merged", prNumber: 99,
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z"))

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 0)
    }

    @Test func activePullRequestSeedsPoolWhenPullRequestsIsEmptyArray() {
        // Empty (not just absent) pullRequests also falls back, like the FE's
        // `workspacePRs.length > 0` guard.
        let ws = makeWorkspace(
            pullRequests: [],
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z"))

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == .init(status: .open, number: 12))
    }

    @Test func activePullRequestMergesWithMonitorsForPrimaryAndCount() {
        // Active PR (older open) wins the primary; the extra monitor counts,
        // and the monitor duplicating the active PR does not.
        let ws = makeWorkspace(
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z"))
        let monitors = [
            makeMonitor(prNumber: 12, createdAt: "2026-08-05T00:00:00Z"), // duplicates primary
            makeMonitor(prNumber: 34, createdAt: "2026-08-10T00:00:00Z"), // other
        ]

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 1)
    }

    @Test func nonEmptyPullRequestsIgnoresActivePullRequest() {
        // An older-open active PR must NOT enter the pool when pullRequests
        // is non-empty — exactly the FE precedence.
        let ws = makeWorkspace(
            pullRequests: [makePr(20, "Open", createdAt: "2026-08-10T00:00:00Z")],
            activePullRequest: makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z"))

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == .init(status: .open, number: 20))
    }

    @Test func bothPoolsAbsentFallsBackToLegacyFields() {
        let ws = makeWorkspace(prStatus: "Merged", prNumber: 42,
                               pullRequests: nil, activePullRequest: nil)

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == .init(status: .merged, number: 42))
        #expect(model.otherMonitorCount == 0)
    }

    // MARK: - Legacy fallback path

    @Test func emptyPoolFallsBackToLegacyPrStatusAndNumber() {
        let ws = makeWorkspace(prStatus: "Merged", prNumber: 42)

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == .init(status: .merged, number: 42))
        #expect(model.otherMonitorCount == 0)
    }

    @Test func legacyFallbackWithoutNumberRendersNumberlessPill() {
        let ws = makeWorkspace(prStatus: "Open")

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == .init(status: .open, number: nil))
    }

    @Test func unknownLegacyStatusRendersNoPill() {
        let ws = makeWorkspace(prStatus: "SomethingNew", prNumber: 5)

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == nil)
        #expect(model.otherMonitorCount == 0)
    }

    @Test func nothingRendersExactlyAsToday() {
        let ws = makeWorkspace()

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: [])
        #expect(model.pill == nil)
        #expect(model.otherMonitorCount == 0)
    }

    // MARK: - "+N" count

    @Test func otherMonitorsBeyondPrimaryAreCounted() {
        let ws = makeWorkspace(pullRequests: [
            makePr(12, "Open", createdAt: "2026-08-01T00:00:00Z"),
        ])
        let monitors = [
            makeMonitor(prNumber: 12),                    // duplicates primary
            makeMonitor(prNumber: 34),                    // other, same repo
            makeMonitor(repo: "other/repo", prNumber: 12) // other, cross-repo
        ]

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 2)
    }

    @Test func crossRepoPrimaryExcludesOnlyItsOwnMonitor() {
        // The primary is a cross-repo monitor row: its exclusion must be
        // repo-qualified via primaryCrossRepo, so the same-numbered
        // workspace-repo monitor still counts.
        let ws = makeWorkspace()
        let monitors = [
            makeMonitor(repo: "other/repo", prNumber: 12,
                        createdAt: "2026-08-01T00:00:00Z"),
            makeMonitor(prNumber: 12, createdAt: "2026-08-10T00:00:00Z"),
        ]

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: monitors)
        #expect(model.pill == .init(status: .open, number: 12))
        #expect(model.otherMonitorCount == 1)
    }

    @Test func completedMonitorWithMergedSnapshotRendersMergedPill() {
        let ws = makeWorkspace()
        let snapshot = MonitoredPr.Snapshot(
            state: "merged", isDraft: false, hasConflicts: false, isBehind: false,
            mergeable: nil, mergeBlockedReason: nil,
            checks: .init(total: 0, passed: 0, failed: 0, pending: 0),
            approvals: .init(decision: "none", have: 0, needed: nil, changesRequested: 0),
            threads: .init(unresolved: 0)
        )
        let monitors = [makeMonitor(prNumber: 8, state: .completed,
                                    updatedAt: "2026-08-14T00:00:00Z",
                                    snapshot: snapshot)]

        let model = WorkspaceRowView.derivePrIndicator(workspace: ws, monitors: monitors)
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

    @Test func pillColorKeepsExistingMapping() {
        #expect(WorkspaceRowView.pillColor(for: .merged) == .purple)
        #expect(WorkspaceRowView.pillColor(for: .open) == .green)
        #expect(WorkspaceRowView.pillColor(for: .draft) == .gray)
        #expect(WorkspaceRowView.pillColor(for: .closed) == .red)
    }
}
