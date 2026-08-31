import Foundation
import Observation
import Testing
@testable import Intent

@MainActor
struct WorkspaceStoreAgentParsingTests {

    // MARK: - Agent summary parsing within parseWorkspace

    @Test func parseWorkspaceWithFullAgentSummary() async throws {
        let dict: [String: Any] = [
            "id": "ws-agent-1",
            "title": "Agent Workspace",
            "agentSummary": [
                "count": 2,
                "agents": [
                    [
                        "id": "agent-001",
                        "name": "Fix Bug",
                        "status": "responding",
                        "specialist": "implementor",
                        "lastActivity": "2026-03-18T12:00:00Z",
                        "isStreaming": true,
                        "isResponding": true
                    ],
                    [
                        "id": "agent-002",
                        "name": "Write Tests",
                        "status": "idle",
                        "specialist": "verifier",
                        "lastActivity": "2026-03-18T11:00:00Z",
                        "isStreaming": false,
                        "isResponding": false
                    ]
                ]
            ] as [String: Any]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.agentSummaryCount == 2)
        #expect(ws?.agentSummaryAgents?.count == 2)

        let first = ws?.agentSummaryAgents?[0]
        #expect(first?.id == "agent-001")
        #expect(first?.name == "Fix Bug")
        #expect(first?.status == "responding")
        #expect(first?.specialist == "implementor")
        #expect(first?.lastActivity == "2026-03-18T12:00:00Z")
        #expect(first?.isStreaming == true)
        #expect(first?.isResponding == true)

        let second = ws?.agentSummaryAgents?[1]
        #expect(second?.id == "agent-002")
        #expect(second?.name == "Write Tests")
        #expect(second?.status == "idle")
        #expect(second?.specialist == "verifier")
        #expect(second?.isStreaming == false)
        #expect(second?.isResponding == false)
    }

    @Test func parseWorkspaceWithMinimalAgentFields() async throws {
        let dict: [String: Any] = [
            "id": "ws-agent-2",
            "title": "Minimal Agent",
            "agentSummary": [
                "count": 1,
                "agents": [
                    ["id": "agent-003", "name": "Helper", "status": "idle"]
                ]
            ] as [String: Any]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.agentSummaryAgents?.count == 1)
        let agent = ws?.agentSummaryAgents?[0]
        #expect(agent?.id == "agent-003")
        #expect(agent?.name == "Helper")
        #expect(agent?.status == "idle")
        #expect(agent?.specialist == nil)
        #expect(agent?.lastActivity == nil)
        #expect(agent?.isStreaming == false)
        #expect(agent?.isResponding == false)
    }

    @Test func parseWorkspaceSkipsAgentsMissingRequiredFields() async throws {
        let dict: [String: Any] = [
            "id": "ws-agent-3",
            "title": "Partial Agents",
            "agentSummary": [
                "count": 3,
                "agents": [
                    ["id": "agent-ok", "name": "Good", "status": "idle"],
                    ["name": "No ID", "status": "idle"],           // missing id
                    ["id": "agent-no-name", "status": "idle"],     // missing name
                    ["id": "agent-no-status", "name": "No Status"] // missing status
                ]
            ] as [String: Any]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.agentSummaryAgents?.count == 1)
        #expect(ws?.agentSummaryAgents?[0].id == "agent-ok")
    }

    @Test func parseWorkspaceWithEmptyAgentsArray() async throws {
        let dict: [String: Any] = [
            "id": "ws-agent-4",
            "title": "Empty Agents",
            "agentSummary": ["count": 0, "agents": [] as [[String: Any]]] as [String: Any]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.agentSummaryCount == 0)
        #expect(ws?.agentSummaryAgents?.count == 0)
    }

    @Test func parseWorkspaceWithNoAgentSummary() async throws {
        let dict: [String: Any] = ["id": "ws-agent-5", "title": "No Summary"]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.agentSummaryCount == nil)
        #expect(ws?.agentSummaryAgents == nil)
    }

    @Test func agentSummaryCountMatchesDictValue() async throws {
        let dict: [String: Any] = [
            "id": "ws-agent-6",
            "title": "Count Check",
            "agentSummary": ["count": 5, "agents": [
                ["id": "a1", "name": "A", "status": "idle"]
            ]] as [String: Any]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        // count comes from dict, not array length
        #expect(ws?.agentSummaryCount == 5)
        #expect(ws?.agentSummaryAgents?.count == 1)
    }

    // MARK: - WorkspaceAgentInfo Codable round-trip

    @Test func agentInfoCodableRoundTrip() async throws {
        let agent = WorkspaceAgentInfo(
            id: "agent-rt", name: "Round Trip", status: "responding",
            specialist: "implementor", lastActivity: "2026-03-18T10:00:00Z",
            isStreaming: true, isResponding: true
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(WorkspaceAgentInfo.self, from: data)
        #expect(decoded == agent)
    }

    @Test func agentInfoCodableWithNilOptionals() async throws {
        let agent = WorkspaceAgentInfo(
            id: "agent-nil", name: "Nil Opts", status: "idle",
            specialist: nil, lastActivity: nil,
            isStreaming: false, isResponding: false
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(WorkspaceAgentInfo.self, from: data)
        #expect(decoded == agent)
        #expect(decoded.specialist == nil)
        #expect(decoded.lastActivity == nil)
    }

    // MARK: - WorkspaceAgentInfo Equatable

    @Test func agentInfoEquality() async throws {
        let a = WorkspaceAgentInfo(id: "x", name: "X", status: "idle", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        let b = WorkspaceAgentInfo(id: "x", name: "X", status: "idle", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        #expect(a == b)
    }

    @Test func agentInfoInequalityDifferentStatus() async throws {
        let a = WorkspaceAgentInfo(id: "x", name: "X", status: "idle", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        let b = WorkspaceAgentInfo(id: "x", name: "X", status: "responding", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        #expect(a != b)
    }
}

// MARK: - lastActivityHighWaterMark regression tests

@MainActor
struct WorkspaceStoreHighWaterMarkTests {

    private func makeWorkspace(id: String, lastActivity: String?) -> Workspace {
        Workspace(
            id: id, title: "WS \(id)", branch: nil, baseRef: nil,
            status: nil, activity: nil, displayStatus: nil,
            lastActivity: lastActivity, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil,
            prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil,
            taskStatsCompleted: nil, taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    // MARK: - updateLocalLastActivity stores max timestamp

    @Test func newerTimestampUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        // First update sets the HWM
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T12:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-03-01T12:00:00Z")
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")

        // Newer timestamp updates the HWM
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T14:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-03-01T14:00:00Z")
        #expect(store.workspaces[0].lastActivity == "2026-03-01T14:00:00Z")
    }

    @Test func olderTimestampIsIgnoredByHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        // Set a HWM with a recent timestamp
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T14:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-03-01T14:00:00Z")

        // Older timestamp should NOT overwrite the HWM
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T12:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-03-01T14:00:00Z")
        // Workspace should still show the newer timestamp
        #expect(store.workspaces[0].lastActivity == "2026-03-01T14:00:00Z")
    }

    // MARK: - _fetchAll merges HWM so timestamps never regress

    @Test func fetchAllMergesHighWaterMarkPreventingRegression() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        // Simulate an optimistic event-driven update with a future timestamp
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T16:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-03-01T16:00:00Z")

        // Simulate what _fetchAll does: parse workspaces with older server data,
        // then apply HWM merge
        var parsed = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T12:00:00Z")]
        store.applyHighWaterMarks(to: &parsed)
        store.workspaces = parsed

        // The HWM timestamp should win over the stale server data
        #expect(store.workspaces[0].lastActivity == "2026-03-01T16:00:00Z")
    }

    @Test func fetchAllUsesServerTimestampWhenNewerThanHWM() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        // Set a modest HWM
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T12:00:00Z")

        // Server returns a newer timestamp — applyHighWaterMarks should preserve it
        var parsed = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T18:00:00Z")]
        store.applyHighWaterMarks(to: &parsed)
        store.workspaces = parsed

        // Server's newer timestamp should be preserved
        #expect(store.workspaces[0].lastActivity == "2026-03-01T18:00:00Z")
    }

    // MARK: - Multiple workspaces maintain independent HWMs

    @Test func multipleWorkspacesMaintainIndependentHighWaterMarks() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [
            makeWorkspace(id: "ws-A", lastActivity: "2026-03-01T10:00:00Z"),
            makeWorkspace(id: "ws-B", lastActivity: "2026-03-01T10:00:00Z"),
            makeWorkspace(id: "ws-C", lastActivity: "2026-03-01T10:00:00Z"),
        ]

        // Update each workspace with different timestamps
        store.updateLocalLastActivity(workspaceId: "ws-A", timestamp: "2026-03-01T14:00:00Z")
        store.updateLocalLastActivity(workspaceId: "ws-B", timestamp: "2026-03-01T16:00:00Z")
        store.updateLocalLastActivity(workspaceId: "ws-C", timestamp: "2026-03-01T12:00:00Z")

        // Each workspace should have its own independent HWM
        #expect(store.lastActivityHighWaterMark["ws-A"] == "2026-03-01T14:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-B"] == "2026-03-01T16:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-C"] == "2026-03-01T12:00:00Z")

        // Verify the workspace lastActivity values match
        #expect(store.workspaces[0].lastActivity == "2026-03-01T14:00:00Z")
        #expect(store.workspaces[1].lastActivity == "2026-03-01T16:00:00Z")
        #expect(store.workspaces[2].lastActivity == "2026-03-01T12:00:00Z")

        // Update ws-A with older timestamp — should not affect ws-A or others
        store.updateLocalLastActivity(workspaceId: "ws-A", timestamp: "2026-03-01T11:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-A"] == "2026-03-01T14:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-B"] == "2026-03-01T16:00:00Z")
        #expect(store.lastActivityHighWaterMark["ws-C"] == "2026-03-01T12:00:00Z")
    }
}

// MARK: - Unread attention flag tests

@MainActor
struct WorkspaceStoreAttentionTests {

    private func makeWorkspace(id: String, attention: String?) -> Workspace {
        Workspace(
            id: id, title: "WS \(id)", branch: nil, baseRef: nil,
            status: nil, activity: nil, displayStatus: nil,
            attention: attention,
            lastActivity: nil, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil,
            prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil,
            taskStatsCompleted: nil, taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    @Test func parseWorkspaceDecodesAttention() async throws {
        let ws = WorkspaceStore.parseWorkspace(
            ["id": "ws-1", "title": "T", "attention": "unread"])
        #expect(ws?.attention == "unread")
    }

    @Test func clearUnreadAttentionLocallyClearsUnread() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].attention == "none")
    }

    @Test func clearUnreadAttentionLocallyGuardedOnUnread() async throws {
        let store = WorkspaceStore(forTesting: true)
        // review_required must survive (mirrors the server-side markSeen guard)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "review_required")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].attention == "review_required")

        // Absent flag stays absent
        store.workspaces = [makeWorkspace(id: "ws-2", attention: nil)]
        store.clearUnreadAttentionLocally(workspaceId: "ws-2")
        #expect(store.workspaces[0].attention == nil)
    }

    @Test func clearUnreadAttentionLocallyUnknownWorkspaceIsNoOp() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-other")
        #expect(store.workspaces[0].attention == "unread")
    }

    @Test func attentionSurvivesLastActivityRebuild() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T12:00:00Z")
        #expect(store.workspaces[0].attention == "unread",
                "The lastActivity rebuild must carry the attention flag through")
    }
}

// MARK: - Waiting flag tests (protocol 6.17)

@MainActor
struct WorkspaceStoreWaitingTests {

    private func makeWorkspace(id: String, waiting: Bool = false, attention: String? = nil) -> Workspace {
        Workspace(
            id: id, title: "WS \(id)", branch: nil, baseRef: nil,
            status: nil, activity: nil, displayStatus: nil,
            attention: attention, waiting: waiting,
            lastActivity: nil, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil,
            prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil,
            taskStatsCompleted: nil, taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    @Test func updateWaitingSetsAndClearsFlag() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]

        store.updateWaiting(workspaceId: "ws-1", waiting: true)
        #expect(store.workspaces[0].waiting == true)

        store.updateWaiting(workspaceId: "ws-1", waiting: false)
        #expect(store.workspaces[0].waiting == false)
    }

    @Test func updateWaitingUnknownWorkspaceIsNoOp() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]
        store.updateWaiting(workspaceId: "ws-other", waiting: true)
        #expect(store.workspaces[0].waiting == false)
    }

    @Test func waitingChangedEventPatchesRowInPlace() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]

        // Wrapped shape from the websocket-event-bridge
        store.handleEvent("event", params: [
            "subscriptionId": "sub-1",
            "event": [
                "type": "workspace:waiting-changed",
                "workspaceId": "ws-1",
                "timestamp": "2026-03-01T12:00:00Z",
                "data": ["workspaceId": "ws-1", "waiting": true] as [String: Any]
            ] as [String: Any]
        ] as [String: Any])
        #expect(store.workspaces[0].waiting == true)

        // Transition back to not-waiting
        store.handleEvent("event", params: [
            "event": [
                "type": "workspace:waiting-changed",
                "workspaceId": "ws-1",
                "data": ["workspaceId": "ws-1", "waiting": false] as [String: Any]
            ] as [String: Any]
        ] as [String: Any])
        #expect(store.workspaces[0].waiting == false)
    }

    @Test func waitingChangedEventLeavesOtherWorkspacesUntouched() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [
            makeWorkspace(id: "ws-1"),
            makeWorkspace(id: "ws-2", waiting: true),
        ]
        store.handleEvent("event", params: [
            "event": [
                "type": "workspace:waiting-changed",
                "workspaceId": "ws-1",
                "data": ["workspaceId": "ws-1", "waiting": true] as [String: Any]
            ] as [String: Any]
        ] as [String: Any])
        #expect(store.workspaces[0].waiting == true)
        #expect(store.workspaces[1].waiting == true)
    }

    @Test func waitingSurvivesLastActivityRebuild() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true)]
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T12:00:00Z")
        #expect(store.workspaces[0].waiting == true,
                "The lastActivity rebuild must carry the waiting flag through")
    }

    @Test func waitingSurvivesHighWaterMarkMerge() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.updateLocalLastActivity(workspaceId: "ws-1", timestamp: "2026-03-01T16:00:00Z")

        var parsed = [WorkspaceStore.parseWorkspace(
            ["id": "ws-1", "title": "T", "waiting": true, "lastActivity": "2026-03-01T12:00:00Z"])!]
        store.applyHighWaterMarks(to: &parsed)
        #expect(parsed[0].lastActivity == "2026-03-01T16:00:00Z")
        #expect(parsed[0].waiting == true,
                "The HWM rebuild must carry the waiting flag through")
    }

    @Test func waitingSurvivesClearUnreadAttention() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true, attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].attention == "none")
        #expect(store.workspaces[0].waiting == true,
                "Clearing unread must not drop the waiting flag")
    }

    @Test func fullRowRefreshDropsWaitingWhenOmitted() async throws {
        // A full-row refresh (workspace.list / snapshot) that omits `waiting`
        // means false — the flag must not stick from an older row.
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true)]

        var parsed = [WorkspaceStore.parseWorkspace(["id": "ws-1", "title": "T"])!]
        store.applyHighWaterMarks(to: &parsed)
        store.publishFetchedWorkspaces(parsed)
        #expect(store.workspaces[0].waiting == false)
    }
}

// MARK: - Fetch publish-order regression tests

@MainActor
struct WorkspaceStorePublishOrderTests {

    /// Regression: first-fetch validation must observe the completed fetch state,
    /// including when the fetched workspace list stays empty.
    @Test func publishFetchedWorkspaces_observerSeesCompletedEmptyFetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let observedCompletedFetch = await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = store.lastUpdated
                _ = store.workspaces
            } onChange: {
                Task { @MainActor in
                    continuation.resume(
                        returning: store.lastUpdated != nil && store.workspaces.isEmpty)
                }
            }
            store.publishFetchedWorkspaces([])
        }
        #expect(observedCompletedFetch,
                "Observation must deliver the completed first-fetch state even when the list stays empty")
    }

    @Test func publishFetchedWorkspaces_updatesWorkspacesAndLastUpdated() async throws {
        let store = WorkspaceStore(forTesting: true)
        #expect(store.lastUpdated == nil)
        let ws = WorkspaceStore.parseWorkspace(["id": "ws-pub-1", "title": "Published"])!
        store.publishFetchedWorkspaces([ws])
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].id == "ws-pub-1")
        #expect(store.lastUpdated != nil)
    }
}

