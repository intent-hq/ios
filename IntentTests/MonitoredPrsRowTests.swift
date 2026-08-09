import Foundation
import Testing
@testable import Intent

/// Display-helper tests for the monitored-PRs chip row (the pure static
/// funcs on `MonitoredPrsRow`; the SwiftUI body itself is not under test).
@MainActor
struct MonitoredPrsRowTests {

    private func makeMonitor(
        repo: String = "octo/repo",
        prNumber: Int = 12,
        title: String? = "Add review wire surface",
        url: String? = "https://github.com/octo/repo/pull/12",
        pendingChanges: [String] = [],
        snapshot: MonitoredPr.Snapshot? = nil
    ) -> MonitoredPr {
        MonitoredPr(
            monitorId: "prm-1", workspaceId: "ws-abc", agentId: "agent-1",
            repo: repo, prNumber: prNumber, state: .active,
            pendingChanges: pendingChanges,
            hasPendingChanges: !pendingChanges.isEmpty,
            createdAt: nil, updatedAt: nil, pendingSince: nil,
            lastChangeAt: nil, lastPolledAt: nil, lastError: nil,
            title: title, url: url, lastSnapshot: snapshot
        )
    }

    private func makeSnapshot(
        checks: MonitoredPr.Snapshot.Checks = .init(total: 0, passed: 0, failed: 0, pending: 0),
        approvals: MonitoredPr.Snapshot.Approvals = .init(decision: "none", have: 0, needed: nil, changesRequested: 0),
        threads: MonitoredPr.Snapshot.Threads = .init(unresolved: 0)
    ) -> MonitoredPr.Snapshot {
        MonitoredPr.Snapshot(
            state: "open", isDraft: false, hasConflicts: false, isBehind: false,
            mergeable: nil, mergeBlockedReason: nil,
            checks: checks, approvals: approvals, threads: threads
        )
    }

    // MARK: - Chip label

    @Test func chipLabelSameRepoIsBareNumber() {
        let monitor = makeMonitor()
        #expect(MonitoredPrsRow.chipLabel(monitor, workspaceRepo: "octo/repo") == "#12")
    }

    @Test func chipLabelCrossRepoIsPrefixed() {
        let monitor = makeMonitor(repo: "other/repo")
        #expect(MonitoredPrsRow.chipLabel(monitor, workspaceRepo: "octo/repo") == "other/repo: #12")
    }

    @Test func chipLabelUnknownWorkspaceRepoFallsBackToBareNumber() {
        let monitor = makeMonitor(repo: "other/repo")
        #expect(MonitoredPrsRow.chipLabel(monitor, workspaceRepo: nil) == "#12")
    }

    // MARK: - PR URL

    @Test func prUrlPrefersWireUrl() {
        let monitor = makeMonitor(url: "https://example.com/pr/12")
        #expect(MonitoredPrsRow.prUrl(monitor) == "https://example.com/pr/12")
    }

    @Test func prUrlFallsBackToCanonicalGithubForm() {
        let monitor = makeMonitor(url: nil)
        #expect(MonitoredPrsRow.prUrl(monitor) == "https://github.com/octo/repo/pull/12")
    }

    // MARK: - Checks summary

    @Test func checksSummaryNilWithoutSnapshotOrChecks() {
        #expect(MonitoredPrsRow.checksSummary(makeMonitor()) == nil)
        let empty = makeMonitor(snapshot: makeSnapshot())
        #expect(MonitoredPrsRow.checksSummary(empty) == nil)
    }

    @Test func checksSummaryPrefersFailingThenPendingThenPassing() {
        let failing = makeMonitor(snapshot: makeSnapshot(
            checks: .init(total: 4, passed: 2, failed: 1, pending: 1)))
        #expect(MonitoredPrsRow.checksSummary(failing) == "1/4 failing")
        let pending = makeMonitor(snapshot: makeSnapshot(
            checks: .init(total: 4, passed: 2, failed: 0, pending: 2)))
        #expect(MonitoredPrsRow.checksSummary(pending) == "2/4 pending")
        let passing = makeMonitor(snapshot: makeSnapshot(
            checks: .init(total: 4, passed: 4, failed: 0, pending: 0)))
        #expect(MonitoredPrsRow.checksSummary(passing) == "4/4 passing")
    }

    // MARK: - Approvals / threads summaries

    @Test func approvalsSummaryIncludesNeededWhenKnown() {
        let known = makeMonitor(snapshot: makeSnapshot(
            approvals: .init(decision: "approved", have: 1, needed: 2, changesRequested: 0)))
        #expect(MonitoredPrsRow.approvalsSummary(known) == "approved (1/2 approvals)")
        let unknown = makeMonitor(snapshot: makeSnapshot(
            approvals: .init(decision: "approved", have: 1, needed: nil, changesRequested: 0)))
        #expect(MonitoredPrsRow.approvalsSummary(unknown) == "approved (1 approvals)")
        #expect(MonitoredPrsRow.approvalsSummary(makeMonitor()) == nil)
    }

    @Test func threadsSummaryPluralizesAndHidesZero() {
        let none = makeMonitor(snapshot: makeSnapshot(threads: .init(unresolved: 0)))
        #expect(MonitoredPrsRow.threadsSummary(none) == nil)
        let one = makeMonitor(snapshot: makeSnapshot(threads: .init(unresolved: 1)))
        #expect(MonitoredPrsRow.threadsSummary(one) == "1 unresolved thread")
        let many = makeMonitor(snapshot: makeSnapshot(threads: .init(unresolved: 3)))
        #expect(MonitoredPrsRow.threadsSummary(many) == "3 unresolved threads")
    }

    // MARK: - Pending / detail lines

    @Test func pendingSummaryPluralizes() {
        #expect(MonitoredPrsRow.pendingSummary(makeMonitor()) == "No pending changes")
        #expect(MonitoredPrsRow.pendingSummary(makeMonitor(pendingChanges: ["a"]))
            == "1 pending change")
        #expect(MonitoredPrsRow.pendingSummary(makeMonitor(pendingChanges: ["a", "b"]))
            == "2 pending changes")
    }

    @Test func detailLinesWithFullSnapshot() {
        let monitor = makeMonitor(
            pendingChanges: ["check ci: pending → failed"],
            snapshot: makeSnapshot(
                checks: .init(total: 3, passed: 2, failed: 1, pending: 0),
                approvals: .init(decision: "approved", have: 1, needed: 1, changesRequested: 0),
                threads: .init(unresolved: 2)
            )
        )
        let lines = MonitoredPrsRow.detailLines(monitor)
        #expect(lines == [
            "Add review wire surface — open",
            "octo/repo#12 · 1/3 failing · approved (1/1 approvals) · 2 unresolved threads",
            "1 pending change"
        ])
    }

    @Test func detailLinesFallBackWithoutTitleOrSnapshot() {
        let monitor = makeMonitor(title: nil)
        let lines = MonitoredPrsRow.detailLines(monitor)
        #expect(lines == ["octo/repo#12", "octo/repo#12", "No pending changes"])
    }
}
