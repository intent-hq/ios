import Foundation
@testable import Intent
import Testing

/// Behavior tests for the WorkspacePrPill pure-logic port, mirroring the
/// Cloudlands `sidebar-changes-utils.ts` reference (selectPrimaryPr,
/// mergeMonitoredPRs, monitorDisplayStatus, countOtherMonitors).
struct WorkspacePrPillTests {
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

    private func makeSnapshot(state: String = "open", isDraft: Bool = false) -> MonitoredPr.Snapshot {
        MonitoredPr.Snapshot(
            state: state,
            isDraft: isDraft,
            hasConflicts: false,
            isBehind: false,
            mergeable: nil,
            mergeBlockedReason: nil,
            checks: .init(total: 0, passed: 0, failed: 0, pending: 0),
            approvals: .init(decision: "none", have: 0, needed: nil, changesRequested: 0),
            threads: .init(unresolved: 0)
        )
    }

    private func pill(
        _ number: Int,
        _ status: WorkspacePrPill.Status,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        crossRepo: String? = nil
    ) -> WorkspacePrPill.PillPr {
        WorkspacePrPill.PillPr(
            number: number,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            crossRepo: crossRepo
        )
    }

    // MARK: - selectPrimaryPr

    @Test func oldestOpenPrWinsOverNewerOpenAndMerged() {
        let prs = [
            pill(30, .merged, updatedAt: "2026-08-15T00:00:00Z"),
            pill(20, .open, createdAt: "2026-08-10T00:00:00Z"),
            pill(10, .open, createdAt: "2026-08-01T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 10)
    }

    @Test func draftCountsAsUnmerged() {
        let prs = [
            pill(20, .open, createdAt: "2026-08-10T00:00:00Z"),
            pill(10, .draft, createdAt: "2026-08-01T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 10)
    }

    @Test func openTiebreakIsLowerNumber() {
        let prs = [
            pill(22, .open, createdAt: "2026-08-01T00:00:00Z"),
            pill(11, .open, createdAt: "2026-08-01T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 11)
    }

    @Test func openWithMissingCreatedAtSortsLast() {
        let prs = [
            pill(5, .open),
            pill(9, .open, createdAt: "2026-08-12T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 9)
    }

    @Test func mergedOnlyPoolPicksLatestUpdated() {
        let prs = [
            pill(10, .merged, updatedAt: "2026-08-01T00:00:00Z"),
            pill(20, .merged, updatedAt: "2026-08-14T00:00:00Z"),
            pill(30, .closed, updatedAt: "2026-08-16T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 20)
    }

    @Test func mergedTiebreakIsHigherNumber() {
        let prs = [
            pill(10, .merged, updatedAt: "2026-08-14T00:00:00Z"),
            pill(20, .merged, updatedAt: "2026-08-14T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 20)
    }

    @Test func mergedWithMissingUpdatedAtSortsLast() {
        let prs = [
            pill(20, .merged),
            pill(10, .merged, updatedAt: "2026-08-01T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 10)
    }

    @Test func closedOnlyPoolPicksFirstRow() {
        let prs = [
            pill(7, .closed, updatedAt: "2026-08-01T00:00:00Z"),
            pill(8, .closed, updatedAt: "2026-08-14T00:00:00Z")
        ]
        #expect(WorkspacePrPill.selectPrimaryPr(prs)?.number == 7)
    }

    @Test func emptyPoolReturnsNilForLegacyFallback() {
        #expect(WorkspacePrPill.selectPrimaryPr([]) == nil)
    }

    // MARK: - mergeMonitoredPRs

    @Test func monitorDuplicatingWorkspacePrDoesNotAppend() {
        let base = [pill(12, .open, createdAt: "2026-08-01T00:00:00Z")]
        let merged = WorkspacePrPill.mergeMonitoredPRs(
            base,
            [makeMonitor(repo: "octo/repo", prNumber: 12)],
            workspaceRepo: "octo/repo"
        )
        #expect(merged == base)
    }

    @Test func unmatchedMonitorAppendsAsMonitorOnlyRow() {
        let merged = WorkspacePrPill.mergeMonitoredPRs(
            [pill(12, .open)],
            [
                makeMonitor(
                    repo: "octo/repo",
                    prNumber: 34,
                    createdAt: "2026-08-05T00:00:00Z",
                    updatedAt: "2026-08-06T00:00:00Z"
                )
            ],
            workspaceRepo: "octo/repo"
        )
        #expect(merged.count == 2)
        let appended = merged[1]
        #expect(appended.number == 34)
        #expect(appended.status == .open)
        #expect(appended.createdAt == "2026-08-05T00:00:00Z")
        #expect(appended.updatedAt == "2026-08-06T00:00:00Z")
        #expect(appended.crossRepo == nil)
        #expect(appended.monitorOnly)
    }

    @Test func crossRepoMonitorAppendsWithCrossRepoEvenOnSameNumber() {
        let merged = WorkspacePrPill.mergeMonitoredPRs(
            [pill(12, .open)],
            [makeMonitor(repo: "other/repo", prNumber: 12)],
            workspaceRepo: "octo/repo"
        )
        #expect(merged.count == 2)
        #expect(merged[1].crossRepo == "other/repo")
        #expect(merged[1].monitorOnly)
    }

    @Test func sameRepoMonitorNeverMatchesCrossRepoRow() {
        let merged = WorkspacePrPill.mergeMonitoredPRs(
            [pill(12, .open, crossRepo: "other/repo")],
            [makeMonitor(repo: "octo/repo", prNumber: 12)],
            workspaceRepo: "octo/repo"
        )
        #expect(merged.count == 2)
        #expect(merged[1].crossRepo == nil)
    }

    @Test func unknownWorkspaceRepoTreatsAllMonitorsAsSameRepo() {
        let merged = WorkspacePrPill.mergeMonitoredPRs(
            [pill(12, .open)],
            [makeMonitor(repo: "other/repo", prNumber: 12)],
            workspaceRepo: nil
        )
        #expect(merged.count == 1)
    }

    // MARK: - monitorDisplayStatus

    @Test func monitorStatusFollowsSnapshotState() {
        #expect(WorkspacePrPill.monitorDisplayStatus(
            makeMonitor(snapshot: makeSnapshot(state: "Merged"))
        ) == .merged)
        #expect(WorkspacePrPill.monitorDisplayStatus(
            makeMonitor(snapshot: makeSnapshot(state: "closed"))
        ) == .closed)
        #expect(WorkspacePrPill.monitorDisplayStatus(
            makeMonitor(snapshot: makeSnapshot(state: "open", isDraft: true))
        ) == .draft)
        #expect(WorkspacePrPill.monitorDisplayStatus(
            makeMonitor(snapshot: makeSnapshot(state: "open"))
        ) == .open)
    }

    @Test func snapshotlessMonitorStatusFallsBackOnLifecycleState() {
        #expect(WorkspacePrPill.monitorDisplayStatus(makeMonitor(state: .completed)) == .closed)
        #expect(WorkspacePrPill.monitorDisplayStatus(makeMonitor(state: .active)) == .open)
    }

    // MARK: - countOtherMonitors

    @Test func monitorMatchingPrimaryIsExcludedFromCount() {
        let monitors = [
            makeMonitor(repo: "octo/repo", prNumber: 12),
            makeMonitor(repo: "octo/repo", prNumber: 34)
        ]
        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: 12,
            repositoryOwner: "octo",
            repositoryName: "repo"
        )
        #expect(count == 1)
    }

    @Test func crossRepoMonitorSharingPrimaryNumberIsCounted() {
        let monitors = [makeMonitor(repo: "other/repo", prNumber: 12)]
        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: 12,
            repositoryOwner: "octo",
            repositoryName: "repo"
        )
        #expect(count == 1)
    }

    @Test func completedMonitorIsRetainedInCount() {
        let monitors = [makeMonitor(repo: "octo/repo", prNumber: 34, state: .completed)]
        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: 12,
            repositoryOwner: "octo",
            repositoryName: "repo"
        )
        #expect(count == 1)
    }

    @Test func primaryCrossRepoScopesTheExclusion() {
        let monitors = [
            makeMonitor(repo: "other/repo", prNumber: 12),
            makeMonitor(repo: "octo/repo", prNumber: 12)
        ]
        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: 12,
            repositoryOwner: "octo",
            repositoryName: "repo",
            primaryCrossRepo: "other/repo"
        )
        #expect(count == 1)
    }

    @Test func unknownWorkspaceRepoMatchesPrimaryByNumberAlone() {
        let monitors = [
            makeMonitor(repo: "other/repo", prNumber: 12),
            makeMonitor(repo: "octo/repo", prNumber: 12)
        ]
        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: 12,
            repositoryOwner: nil,
            repositoryName: nil
        )
        #expect(count == 0)
    }

    @Test func nilPrimaryNumberCountsEveryMonitor() {
        let monitors = [makeMonitor(repo: "octo/repo", prNumber: 12)]
        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: nil,
            repositoryOwner: "octo",
            repositoryName: "repo"
        )
        #expect(count == 1)
    }

    // MARK: - Status wire mapping

    @Test func wireStatusMapsToDisplayBuckets() {
        #expect(WorkspacePrPill.Status(wire: "Open") == .open)
        #expect(WorkspacePrPill.Status(wire: "Merged") == .merged)
        #expect(WorkspacePrPill.Status(wire: "Draft") == .draft)
        #expect(WorkspacePrPill.Status(wire: "Closed") == .closed)
        #expect(WorkspacePrPill.Status(wire: "SomethingNew") == .closed)
    }

    @Test func pillPrProjectsWorkspacePullRequestFields() {
        let pullRequest = WorkspacePullRequest(
            number: 42,
            status: "Draft",
            title: "t",
            url: "u",
            createdAt: "2026-08-01T00:00:00Z",
            updatedAt: "2026-08-02T00:00:00Z"
        )
        let row = WorkspacePrPill.PillPr(pullRequest)
        #expect(row.number == 42)
        #expect(row.status == .draft)
        #expect(row.createdAt == "2026-08-01T00:00:00Z")
        #expect(row.updatedAt == "2026-08-02T00:00:00Z")
        #expect(row.crossRepo == nil)
        #expect(!row.monitorOnly)
    }

    // MARK: - End-to-end pill derivation

    @Test func monitoredMergedPrLosesToOlderOpenWorkspacePr() {
        let base = [
            pill(10, .open, createdAt: "2026-08-01T00:00:00Z"),
            pill(20, .open, createdAt: "2026-08-10T00:00:00Z")
        ]
        let merged = WorkspacePrPill.mergeMonitoredPRs(
            base,
            [
                makeMonitor(
                    repo: "octo/repo",
                    prNumber: 99,
                    createdAt: "2026-07-01T00:00:00Z",
                    snapshot: makeSnapshot(state: "merged")
                )
            ],
            workspaceRepo: "octo/repo"
        )
        let primary = WorkspacePrPill.selectPrimaryPr(merged)
        #expect(primary?.number == 10)
        let count = WorkspacePrPill.countOtherMonitors(
            [makeMonitor(repo: "octo/repo", prNumber: 99)],
            primaryPrNumber: primary?.number,
            repositoryOwner: "octo",
            repositoryName: "repo",
            primaryCrossRepo: primary?.crossRepo
        )
        #expect(count == 1)
    }
}
