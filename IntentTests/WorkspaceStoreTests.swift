import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

@MainActor
struct WorkspaceStoreAgentParsingTests {
    // MARK: - Agent summary parsing within parseWorkspace

    @Test func parseWorkspaceWithFullAgentSummary() async {
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
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryCount == 2)
        #expect(workspace?.agentSummaryAgents?.count == 2)

        let first = workspace?.agentSummaryAgents?[0]
        #expect(first?.id == "agent-001")
        #expect(first?.name == "Fix Bug")
        #expect(first?.status == "responding")
        #expect(first?.specialist == "implementor")
        #expect(first?.lastActivity == "2026-03-18T12:00:00Z")
        #expect(first?.isStreaming == true)
        #expect(first?.isResponding == true)

        let second = workspace?.agentSummaryAgents?[1]
        #expect(second?.id == "agent-002")
        #expect(second?.name == "Write Tests")
        #expect(second?.status == "idle")
        #expect(second?.specialist == "verifier")
        #expect(second?.isStreaming == false)
        #expect(second?.isResponding == false)
    }

    @Test func parseWorkspaceWithMinimalAgentFields() async {
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
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryAgents?.count == 1)
        let agent = workspace?.agentSummaryAgents?[0]
        #expect(agent?.id == "agent-003")
        #expect(agent?.name == "Helper")
        #expect(agent?.status == "idle")
        #expect(agent?.specialist == nil)
        #expect(agent?.lastActivity == nil)
        #expect(agent?.isStreaming == false)
        #expect(agent?.isResponding == false)
    }

    @Test func parseWorkspaceSkipsAgentsMissingRequiredFields() async {
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
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryAgents?.count == 1)
        #expect(workspace?.agentSummaryAgents?[0].id == "agent-ok")
    }

    @Test func parseWorkspaceWithEmptyAgentsArray() async {
        let dict: [String: Any] = [
            "id": "ws-agent-4",
            "title": "Empty Agents",
            "agentSummary": ["count": 0, "agents": [] as [[String: Any]]] as [String: Any]
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryCount == 0)
        #expect(workspace?.agentSummaryAgents?.isEmpty)
    }

    @Test func parseWorkspaceWithNoAgentSummary() async {
        let dict: [String: Any] = ["id": "ws-agent-5", "title": "No Summary"]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryCount == nil)
        #expect(workspace?.agentSummaryAgents == nil)
    }

    @Test func agentSummaryCountMatchesDictValue() async {
        let dict: [String: Any] = [
            "id": "ws-agent-6",
            "title": "Count Check",
            "agentSummary": [
                "count": 5,
                "agents": [
                    ["id": "a1", "name": "A", "status": "idle"]
                ]
            ] as [String: Any]
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        // count comes from dict, not array length
        #expect(workspace?.agentSummaryCount == 5)
        #expect(workspace?.agentSummaryAgents?.count == 1)
    }

    // MARK: - WorkspaceAgentInfo Codable round-trip

    @Test func agentInfoCodableRoundTrip() async throws {
        let agent = WorkspaceAgentInfo(
            id: "agent-rt",
            name: "Round Trip",
            status: "responding",
            specialist: "implementor",
            lastActivity: "2026-03-18T10:00:00Z",
            isStreaming: true,
            isResponding: true
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(WorkspaceAgentInfo.self, from: data)
        #expect(decoded == agent)
    }

    @Test func agentInfoCodableWithNilOptionals() async throws {
        let agent = WorkspaceAgentInfo(
            id: "agent-nil",
            name: "Nil Opts",
            status: "idle",
            specialist: nil,
            lastActivity: nil,
            isStreaming: false,
            isResponding: false
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(WorkspaceAgentInfo.self, from: data)
        #expect(decoded == agent)
        #expect(decoded.specialist == nil)
        #expect(decoded.lastActivity == nil)
    }

    // MARK: - WorkspaceAgentInfo Equatable

    @Test func agentInfoEquality() async {
        let firstAgent = WorkspaceAgentInfo(id: "x", name: "X", status: "idle", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        let secondAgent = WorkspaceAgentInfo(id: "x", name: "X", status: "idle", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        #expect(firstAgent == secondAgent)
    }

    @Test func agentInfoInequalityDifferentStatus() async {
        let firstAgent = WorkspaceAgentInfo(id: "x", name: "X", status: "idle", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        let secondAgent = WorkspaceAgentInfo(id: "x", name: "X", status: "responding", specialist: nil, lastActivity: nil, isStreaming: false, isResponding: false)
        #expect(firstAgent != secondAgent)
    }
}

// MARK: - lastActivity mirrors intentd (no client-side bumping)

@MainActor
struct WorkspaceStoreLastActivityTests {
    private func makeWorkspace(id: String, lastActivity: String?) -> Workspace {
        Workspace(
            id: id,
            title: "WS \(id)",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil,
            lastActivity: lastActivity,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            agentSummaryAgents: nil
        )
    }

    private func workspaceUpdatedEvent(workspaceId: String, lastActivity: String) -> [String: Any] {
        [
            "event": [
                "type": "workspace:updated",
                "workspaceId": workspaceId,
                "timestamp": lastActivity,
                "data": [
                    "workspaceId": workspaceId,
                    "changes": ["lastActivity": lastActivity]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - workspace:updated { changes.lastActivity } patches the row in place

    @Test func workspaceUpdatedDeltaPatchesLastActivityInPlace() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        store.handleEvent("event", params: workspaceUpdatedEvent(
            workspaceId: "ws-1",
            lastActivity: "2026-03-01T12:00:00Z"
        ))
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }

    @Test func workspaceUpdatedDeltaIsAppliedVerbatimWithoutMonotonicGuard() async {
        // intentd guarantees monotonicity; the client applies whatever it sent.
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T14:00:00Z")]

        store.handleEvent("event", params: workspaceUpdatedEvent(
            workspaceId: "ws-1",
            lastActivity: "2026-03-01T12:00:00Z"
        ))
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }

    @Test func workspaceUpdatedDeltaLeavesOtherWorkspacesUntouched() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [
            makeWorkspace(id: "ws-A", lastActivity: "2026-03-01T10:00:00Z"),
            makeWorkspace(id: "ws-B", lastActivity: "2026-03-01T10:00:00Z")
        ]

        store.handleEvent("event", params: workspaceUpdatedEvent(
            workspaceId: "ws-A",
            lastActivity: "2026-03-01T14:00:00Z"
        ))
        #expect(store.workspaces[0].lastActivity == "2026-03-01T14:00:00Z")
        #expect(store.workspaces[1].lastActivity == "2026-03-01T10:00:00Z")
    }

    @Test func updateLastActivityUnknownWorkspaceIsNoOp() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]
        store.updateLastActivity(workspaceId: "ws-other", lastActivity: "2026-03-01T12:00:00Z")
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].lastActivity == "2026-03-01T10:00:00Z")
    }

    // MARK: - Fetched rows are published exactly as received

    @Test func fetchedRowsAreNotOverriddenByEarlierDelta() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]
        store.updateLastActivity(workspaceId: "ws-1", lastActivity: "2026-03-01T16:00:00Z")
        #expect(store.workspaces[0].lastActivity == "2026-03-01T16:00:00Z")

        // A later workspace.list / snapshot carrying an older value is the
        // daemon's truth — no high-water mark is applied on top of it.
        store.publishFetchedWorkspaces([makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T12:00:00Z")])
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }

    @Test func addOrUpdatePublishesRowAsReceived() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T16:00:00Z")]

        store.addOrUpdate(makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T12:00:00Z"))
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }
}

// MARK: - Unread attention flag tests

@MainActor
struct WorkspaceStoreAttentionTests {
    private func makeWorkspace(id: String, attention: String?) -> Workspace {
        Workspace(
            id: id,
            title: "WS \(id)",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil,
            attention: attention,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            agentSummaryAgents: nil
        )
    }

    @Test func parseWorkspaceDecodesAttention() async {
        let workspace = WorkspaceStore.parseWorkspace(
            ["id": "ws-1", "title": "T", "attention": "unread"]
        )
        #expect(workspace?.attention == "unread")
    }

    @Test func clearUnreadAttentionLocallyClearsUnread() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].attention == "none")
    }

    @Test func clearUnreadAttentionLocallyGuardedOnUnread() async {
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

    @Test func clearUnreadAttentionLocallyUnknownWorkspaceIsNoOp() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-other")
        #expect(store.workspaces[0].attention == "unread")
    }

    @Test func attentionSurvivesLastActivityRebuild() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.updateLastActivity(workspaceId: "ws-1", lastActivity: "2026-03-01T12:00:00Z")
        #expect(
            store.workspaces[0].attention == "unread",
            "The lastActivity rebuild must carry the attention flag through"
        )
    }
}

// MARK: - Waiting flag tests (protocol 6.17)

@MainActor
struct WorkspaceStoreWaitingTests {
    private func makeWorkspace(id: String, waiting: Bool = false, attention: String? = nil) -> Workspace {
        Workspace(
            id: id,
            title: "WS \(id)",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil,
            attention: attention,
            waiting: waiting,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            agentSummaryAgents: nil
        )
    }

    @Test func updateWaitingSetsAndClearsFlag() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]

        store.updateWaiting(workspaceId: "ws-1", waiting: true)
        #expect(store.workspaces[0].waiting == true)

        store.updateWaiting(workspaceId: "ws-1", waiting: false)
        #expect(store.workspaces[0].waiting == false)
    }

    @Test func updateWaitingUnknownWorkspaceIsNoOp() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]
        store.updateWaiting(workspaceId: "ws-other", waiting: true)
        #expect(store.workspaces[0].waiting == false)
    }

    @Test func waitingChangedEventPatchesRowInPlace() async {
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

    @Test func waitingChangedEventLeavesOtherWorkspacesUntouched() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [
            makeWorkspace(id: "ws-1"),
            makeWorkspace(id: "ws-2", waiting: true)
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

    @Test func waitingSurvivesLastActivityRebuild() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true)]
        store.updateLastActivity(workspaceId: "ws-1", lastActivity: "2026-03-01T12:00:00Z")
        #expect(
            store.workspaces[0].waiting == true,
            "The lastActivity rebuild must carry the waiting flag through"
        )
    }

    @Test func waitingSurvivesClearUnreadAttention() async {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true, attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].attention == "none")
        #expect(
            store.workspaces[0].waiting == true,
            "Clearing unread must not drop the waiting flag"
        )
    }

    @Test func fullRowRefreshDropsWaitingWhenOmitted() async throws {
        // A full-row refresh (workspace.list / snapshot) that omits `waiting`
        // means false — the flag must not stick from an older row.
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true)]

        let parsedWorkspace = try #require(WorkspaceStore.parseWorkspace(["id": "ws-1", "title": "T"]))
        store.publishFetchedWorkspaces([parsedWorkspace])
        #expect(store.workspaces[0].waiting == false)
    }
}

// MARK: - Fetch publish-order regression tests

@MainActor
struct WorkspaceStorePublishOrderTests {
    /// Regression: workspace observers must see the completed fetch timestamp at
    /// the exact moment a fetched workspace list invalidates their dependency.
    @Test func publishFetchedWorkspaces_observerSeesLastUpdatedAtInvalidation() throws {
        let store = WorkspaceStore(forTesting: true)
        let observedLastUpdated = Mutex<Bool?>(nil)
        withObservationTracking {
            _ = store.workspaces
        } onChange: {
            MainActor.assumeIsolated {
                observedLastUpdated.withLock { lastUpdatedWasObserved in
                    lastUpdatedWasObserved = store.lastUpdated != nil
                }
            }
        }
        let workspace = try #require(WorkspaceStore.parseWorkspace(["id": "ws-observed", "title": "Observed"]))
        store.publishFetchedWorkspaces([workspace])

        #expect(
            observedLastUpdated.withLock { $0 } == true,
            "lastUpdated must already be set when workspaces invalidates"
        )
        #expect(store.workspaces.map(\.id) == ["ws-observed"])
    }

    @Test func publishFetchedWorkspaces_updatesWorkspacesAndLastUpdated() async throws {
        let store = WorkspaceStore(forTesting: true)
        #expect(store.lastUpdated == nil)
        let workspace = try #require(WorkspaceStore.parseWorkspace(["id": "ws-pub-1", "title": "Published"]))
        store.publishFetchedWorkspaces([workspace])
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].id == "ws-pub-1")
        #expect(store.lastUpdated != nil)
    }
}

// MARK: - Per-connection routing

/// Stores constructed over distinct injected connections (one per pinned
/// backend session) must fetch, subscribe, and publish independently.
@MainActor
struct WorkspaceStoreConnectionRoutingTests {
    /// Poll (bounded) until the condition holds — avoids fixed-sleep
    /// flakiness for assertions on Task-spawned work.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func storesOverDistinctConnectionsStayIsolated() async throws {
        let fakeA = FakeConnectionManager()
        fakeA.responseMap["workspace.list"] = [
            "workspaces": [["id": "ws-a", "title": "Backend A"]]
        ]
        fakeA.responseMap["workspace.subscribe"] = ["subscriptionId": "sub-a"]
        let fakeB = FakeConnectionManager()
        fakeB.responseMap["workspace.list"] = [
            "workspaces": [["id": "ws-b", "title": "Backend B"]]
        ]
        fakeB.responseMap["workspace.subscribe"] = ["subscriptionId": "sub-b"]
        let storeA = WorkspaceStore(connectionManager: fakeA)
        let storeB = WorkspaceStore(connectionManager: fakeB)

        fakeA.simulateConnect()
        try await waitFor { storeA.workspaces.map(\.id) == ["ws-a"] }

        #expect(storeA.workspaces.map(\.id) == ["ws-a"])
        #expect(storeB.workspaces.isEmpty)
        #expect(!fakeB.didCallMethod("workspace.list"))

        fakeB.simulateConnect()
        try await waitFor { storeB.workspaces.map(\.id) == ["ws-b"] }

        #expect(storeB.workspaces.map(\.id) == ["ws-b"])
        #expect(
            storeA.workspaces.map(\.id) == ["ws-a"],
            "Store A must be untouched by store B's connection"
        )
        #expect(fakeA.hasSubscriptionHandler(id: "sub-a"))
        #expect(fakeB.hasSubscriptionHandler(id: "sub-b"))
        #expect(!fakeA.hasSubscriptionHandler(id: "sub-b"))
        #expect(!fakeB.hasSubscriptionHandler(id: "sub-a"))
    }
}
