import Foundation
@testable import Intent
import Testing

@MainActor
struct MonitoredPrStoreTests {
    private struct StateExpectation {
        let rawValue: String
        let state: MonitoredPr.State
        let isActive: Bool
    }

    /// The full §5.42 `prMonitor.list` sample row from PROTOCOL.md.
    func makeMonitorDict(
        monitorId: String = "prm-1",
        state: String = "active"
    ) -> [String: Any] {
        [
            "monitorId": monitorId,
            "workspaceId": "ws-abc",
            "agentId": "agent-1",
            "repo": "octo/repo",
            "prNumber": 12,
            "state": state,
            "pendingChanges": ["check ci: pending → failed"],
            "hasPendingChanges": true,
            "pendingSince": "2026-08-07T12:00:00.000Z",
            "lastChangeAt": "2026-08-07T12:00:00.000Z",
            "lastPolledAt": "2026-08-07T12:00:30.000Z",
            "title": "Add review wire surface",
            "url": "https://github.com/octo/repo/pull/12",
            "lastSnapshot": [
                "state": "open",
                "isDraft": false,
                "hasConflicts": false,
                "isBehind": false,
                "mergeable": true,
                "mergeBlockedReason": "1 required check failing (ci)",
                "checks": [
                    "total": 3,
                    "passed": 2,
                    "failed": 1,
                    "pending": 0,
                    "failingRequired": ["ci"],
                    "pendingRequired": [] as [String],
                    "requiredKnown": true
                ],
                "approvals": [
                    "decision": "approved",
                    "have": 1,
                    "needed": 1,
                    "changesRequested": 0
                ],
                "threads": ["unresolved": 0, "resolutionRequired": true],
                "rulesKnown": true
            ] as [String: Any],
            "createdAt": "2026-08-07T11:58:00.000Z",
            "updatedAt": "2026-08-07T12:00:30.000Z"
        ]
    }

    /// A minimal wire row: only the always-present fields (a monitor that
    /// has no successful poll baseline yet).
    func makeMinimalMonitorDict() -> [String: Any] {
        [
            "monitorId": "prm-2",
            "workspaceId": "ws-abc",
            "agentId": "agent-1",
            "repo": "octo/repo",
            "prNumber": 34,
            "state": "active",
            "pendingChanges": [] as [String],
            "hasPendingChanges": false,
            "createdAt": "2026-08-07T11:58:00.000Z",
            "updatedAt": "2026-08-07T11:58:00.000Z"
        ]
    }

    // MARK: - Model parsing

    @Test func parsesFullProtocolSample() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        #expect(monitor.monitorId == "prm-1")
        #expect(monitor.workspaceId == "ws-abc")
        #expect(monitor.agentId == "agent-1")
        #expect(monitor.repo == "octo/repo")
        #expect(monitor.prNumber == 12)
        #expect(monitor.state == .active)
        #expect(monitor.pendingChanges == ["check ci: pending → failed"])
        #expect(monitor.hasPendingChanges == true)
        #expect(monitor.pendingSince == "2026-08-07T12:00:00.000Z")
        #expect(monitor.lastChangeAt == "2026-08-07T12:00:00.000Z")
        #expect(monitor.lastPolledAt == "2026-08-07T12:00:30.000Z")
        #expect(monitor.lastError == nil)
        #expect(monitor.title == "Add review wire surface")
        #expect(monitor.url == "https://github.com/octo/repo/pull/12")
        #expect(monitor.createdAt == "2026-08-07T11:58:00.000Z")
        #expect(monitor.updatedAt == "2026-08-07T12:00:30.000Z")

        let snapshot = try #require(monitor.lastSnapshot)
        #expect(snapshot.state == "open")
        #expect(snapshot.isDraft == false)
        #expect(snapshot.hasConflicts == false)
        #expect(snapshot.isBehind == false)
        #expect(snapshot.mergeability == .mergeable)
        #expect(snapshot.mergeBlockedReason == "1 required check failing (ci)")
        #expect(snapshot.checks == .init(total: 3, passed: 2, failed: 1, pending: 0))
        #expect(snapshot.approvals == .init(
            decision: "approved",
            have: 1,
            needed: 1,
            changesRequested: 0
        ))
        #expect(snapshot.threads == .init(unresolved: 0))
    }

    @Test func parsesLastErrorWhenPresent() throws {
        var dict = makeMonitorDict()
        dict["lastError"] = "GitHub API rate limit exceeded"
        let monitor = try #require(MonitoredPr.parseMonitor(dict))
        #expect(monitor.lastError == "GitHub API rate limit exceeded")
    }

    @Test func parsesMinimalRowWithPresenceDetectedNils() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMinimalMonitorDict()))
        #expect(monitor.pendingChanges.isEmpty)
        #expect(monitor.hasPendingChanges == false)
        #expect(monitor.pendingSince == nil)
        #expect(monitor.lastChangeAt == nil)
        #expect(monitor.lastPolledAt == nil)
        #expect(monitor.lastError == nil)
        #expect(monitor.title == nil)
        #expect(monitor.url == nil)
        #expect(monitor.lastSnapshot == nil)
    }

    @Test func parsesSnapshotOptionalFieldsAsNilWhenAbsent() throws {
        var dict = makeMonitorDict()
        // A degraded snapshot: `mergeable` still computing,
        // no blocked reason, unreadable branch rules (needed omitted).
        dict["lastSnapshot"] = [
            "state": "open",
            "isDraft": true,
            "hasConflicts": true,
            "isBehind": true,
            "checks": ["total": 0, "passed": 0, "failed": 0, "pending": 0],
            "approvals": ["decision": "review_required", "have": 0, "changesRequested": 2],
            "threads": ["unresolved": 3]
        ] as [String: Any]
        let monitor = try #require(MonitoredPr.parseMonitor(dict))
        let snapshot = try #require(monitor.lastSnapshot)
        #expect(snapshot.mergeability == .computing)
        #expect(snapshot.mergeBlockedReason == nil)
        #expect(snapshot.isDraft == true)
        #expect(snapshot.hasConflicts == true)
        #expect(snapshot.isBehind == true)
        #expect(snapshot.approvals == .init(
            decision: "review_required",
            have: 0,
            needed: nil,
            changesRequested: 2
        ))
        #expect(snapshot.threads == .init(unresolved: 3))
    }

    @Test func parsesAllStatesAndIsActive() throws {
        let expectations = [
            StateExpectation(rawValue: "active", state: .active, isActive: true),
            StateExpectation(rawValue: "completed", state: .completed, isActive: false),
            StateExpectation(rawValue: "cancelled", state: .cancelled, isActive: false)
        ]
        for expectation in expectations {
            let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict(state: expectation.rawValue)))
            #expect(monitor.state == expectation.state)
            #expect(monitor.isActive == expectation.isActive)
        }
    }

    @Test func rejectsMissingRequiredOrUnknownState() {
        var missingId = makeMonitorDict()
        missingId.removeValue(forKey: "monitorId")
        #expect(MonitoredPr.parseMonitor(missingId) == nil)
        var missingRepo = makeMonitorDict()
        missingRepo.removeValue(forKey: "repo")
        #expect(MonitoredPr.parseMonitor(missingRepo) == nil)
        var missingPrNumber = makeMonitorDict()
        missingPrNumber.removeValue(forKey: "prNumber")
        #expect(MonitoredPr.parseMonitor(missingPrNumber) == nil)
        #expect(MonitoredPr.parseMonitor(makeMonitorDict(state: "someFutureState")) == nil)
    }

    /// The canonical §6.5 `prMonitor:*` event data payload.
    func makeEventData(
        monitorId: String = "prm-1",
        state: String = "active",
        changes: [String] = []
    ) -> [String: Any] {
        var data: [String: Any] = [
            "workspaceId": "ws-abc",
            "agentId": "agent-1",
            "monitorId": monitorId,
            "repo": "octo/repo",
            "prNumber": 12,
            "state": state
        ]
        if !changes.isEmpty { data["changes"] = changes }
        return data
    }
}
