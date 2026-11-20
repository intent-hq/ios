import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

@MainActor
struct WorkspaceStoreAgentParsingTests {
    @Test func parseWorkspaceWithFullAgentSummary() {
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
        #expect(workspace?.agentSummaryAgents.count == 2)

        let first = workspace?.agentSummaryAgents[0]
        #expect(first?.id == "agent-001")
        #expect(first?.name == "Fix Bug")
        #expect(first?.status == "responding")
        #expect(first?.specialist == "implementor")
        #expect(first?.lastActivity == "2026-03-18T12:00:00Z")
        #expect(first?.isStreaming == true)
        #expect(first?.isResponding == true)

        let second = workspace?.agentSummaryAgents[1]
        #expect(second?.id == "agent-002")
        #expect(second?.name == "Write Tests")
        #expect(second?.status == "idle")
        #expect(second?.specialist == "verifier")
        #expect(second?.isStreaming == false)
        #expect(second?.isResponding == false)
    }

    @Test func parseWorkspaceWithMinimalAgentFields() {
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
        #expect(workspace?.agentSummaryAgents.count == 1)
        let agent = workspace?.agentSummaryAgents[0]
        #expect(agent?.id == "agent-003")
        #expect(agent?.name == "Helper")
        #expect(agent?.status == "idle")
        #expect(agent?.specialist == nil)
        #expect(agent?.lastActivity == nil)
        #expect(agent?.isStreaming == false)
        #expect(agent?.isResponding == false)
    }

    @Test func parseWorkspaceSkipsAgentsMissingRequiredFields() {
        let dict: [String: Any] = [
            "id": "ws-agent-3",
            "title": "Partial Agents",
            "agentSummary": [
                "count": 3,
                "agents": [
                    ["id": "agent-ok", "name": "Good", "status": "idle"],
                    ["name": "No ID", "status": "idle"],
                    ["id": "agent-no-name", "status": "idle"],
                    ["id": "agent-no-status", "name": "No Status"]
                ]
            ] as [String: Any]
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryAgents.count == 1)
        #expect(workspace?.agentSummaryAgents[0].id == "agent-ok")
    }

    @Test func parseWorkspaceWithEmptyAgentsArray() {
        let dict: [String: Any] = [
            "id": "ws-agent-4",
            "title": "Empty Agents",
            "agentSummary": ["count": 0, "agents": [] as [[String: Any]]] as [String: Any]
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryCount == 0)
        #expect(workspace?.agentSummaryAgents.isEmpty == true)
    }

    @Test func parseWorkspaceWithNoAgentSummary() {
        let dict: [String: Any] = ["id": "ws-agent-5", "title": "No Summary"]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.agentSummaryCount == nil)
        #expect(workspace?.agentSummaryAgents.isEmpty == true)
        #expect(workspace?.agentSummaryWasReported == false)
    }

    @Test func agentSummaryCountMatchesDictValue() {
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
        #expect(workspace?.agentSummaryCount == 5)
        #expect(workspace?.agentSummaryAgents.count == 1)
    }

    @Test func agentInfoCodableRoundTrip() throws {
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

    @Test func agentInfoCodableWithNilOptionals() throws {
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
}

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
            agentSummaryAgents: []
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

    @Test func workspaceUpdatedDeltaPatchesLastActivityInPlace() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        store.handleEvent(
            "event",
            params: workspaceUpdatedEvent(
                workspaceId: "ws-1",
                lastActivity: "2026-03-01T12:00:00Z"
            )
        )
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }

    @Test func workspaceUpdatedDeltaIsAppliedVerbatimWithoutMonotonicGuard() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T14:00:00Z")]

        store.handleEvent(
            "event",
            params: workspaceUpdatedEvent(
                workspaceId: "ws-1",
                lastActivity: "2026-03-01T12:00:00Z"
            )
        )
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }

    @Test func workspaceUpdatedDeltaLeavesOtherWorkspacesUntouched() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [
            makeWorkspace(id: "ws-A", lastActivity: "2026-03-01T10:00:00Z"),
            makeWorkspace(id: "ws-B", lastActivity: "2026-03-01T10:00:00Z")
        ]

        store.handleEvent(
            "event",
            params: workspaceUpdatedEvent(
                workspaceId: "ws-A",
                lastActivity: "2026-03-01T14:00:00Z"
            )
        )
        #expect(store.workspaces[0].lastActivity == "2026-03-01T14:00:00Z")
        #expect(store.workspaces[1].lastActivity == "2026-03-01T10:00:00Z")
    }

    @Test func updateLastActivityUnknownWorkspaceIsNoOp() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]
        store.updateLastActivity(workspaceId: "ws-other", lastActivity: "2026-03-01T12:00:00Z")
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].lastActivity == "2026-03-01T10:00:00Z")
    }

    @Test func fetchedRowsAreNotOverriddenByEarlierDelta() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]
        store.updateLastActivity(workspaceId: "ws-1", lastActivity: "2026-03-01T16:00:00Z")
        #expect(store.workspaces[0].lastActivity == "2026-03-01T16:00:00Z")

        store.publishFetchedWorkspaces([makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T12:00:00Z")])
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }

    @Test func addOrUpdatePublishesRowAsReceived() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T16:00:00Z")]

        store.addOrUpdate(makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T12:00:00Z"))
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
    }
}

@MainActor
struct WorkspaceStoreChiefFilterTests {
    private let chiefId = Workspace.chiefWorkspaceId

    private var chiefRow: [String: Any] {
        ["id": chiefId, "title": "Chief of Staff", "activity": "agent_running"]
    }

    private var realRow: [String: Any] {
        ["id": "ws-1", "title": "Real Workspace"]
    }

    private func makeLiveStore(snapshot: [[String: Any]]) async -> WorkspaceStore {
        let store = WorkspaceStore(forTesting: true)
        await store.setTestReconciler(DeltaReconciler<Workspace>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceStore.parseWorkspace(dict) }
        ))
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": snapshot
        ])
        return store
    }

    private func deltaPush(seq: Int, added: [[String: Any]] = [], updated: [[String: Any]] = []) -> [String: Any] {
        [
            "subscriptionId": "sub-123",
            "kind": "delta",
            "seq": seq,
            "delta": ["added": added, "updated": updated, "removedIds": [String]()] as [String: Any]
        ]
    }

    @Test func chiefWorkspaceIdMatchesDaemonSentinel() {
        #expect(chiefId == "__chief__")
    }

    @Test func parseWorkspaceReturnsNilForChief() {
        #expect(WorkspaceStore.parseWorkspace(chiefRow) == nil)
        #expect(WorkspaceStore.parseWorkspace(realRow) != nil)
    }

    @Test func parseWorkspacesDropsChiefFromListResponse() {
        let parsed = WorkspaceStore.parseWorkspaces(from: ["workspaces": [chiefRow, realRow]])
        #expect(parsed.map(\.id) == ["ws-1"])
    }

    @Test func snapshotContainingChiefPublishesWithoutIt() async {
        let store = await makeLiveStore(snapshot: [chiefRow, realRow])
        #expect(store.workspaces.map(\.id) == ["ws-1"])
        #expect(store.lastUpdated != nil)
    }

    @Test func deltaUpdatedChiefDoesNotInsertIt() async {
        let store = await makeLiveStore(snapshot: [realRow])
        store.handleEvent("subscription.push", params: deltaPush(seq: 1, updated: [chiefRow]))
        #expect(store.workspaces.map(\.id) == ["ws-1"])

        store.handleEvent("subscription.push", params: deltaPush(
            seq: 2,
            added: [["id": "ws-2", "title": "Second"]]
        ))
        #expect(store.workspaces.map(\.id) == ["ws-1", "ws-2"])
    }

    @Test func deltaAddedChiefDoesNotInsertIt() async {
        let store = await makeLiveStore(snapshot: [realRow])
        store.handleEvent("subscription.push", params: deltaPush(seq: 1, added: [chiefRow]))
        #expect(store.workspaces.map(\.id) == ["ws-1"])
    }

    @Test func legacyWorkspaceUpdatedPatchForChiefDoesNotInsertIt() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [try #require(WorkspaceStore.parseWorkspace(realRow))]

        store.handleEvent("events.event", params: [
            "event": [
                "type": "workspace:updated",
                "workspaceId": chiefId,
                "data": [
                    "workspaceId": chiefId,
                    "changes": ["lastActivity": "2026-09-18T12:00:00Z"]
                ] as [String: Any]
            ] as [String: Any]
        ])
        #expect(store.workspaces.map(\.id) == ["ws-1"])
    }

    @Test func legacyWorkspaceUpdatedRefetchForChiefDoesNotInsertIt() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.list"] = ["workspaces": [chiefRow, realRow]]
        let store = WorkspaceStore(connectionManager: fake)

        store.handleEvent("events.event", params: [
            "event": [
                "type": "workspace:updated",
                "workspaceId": chiefId,
                "data": [
                    "workspaceId": chiefId,
                    "changes": ["statusMessage": "Working"]
                ] as [String: Any]
            ] as [String: Any]
        ])
        try await fake.waitForRequests("workspace.list")
        try await waitUntil("workspace.list published") { store.lastUpdated != nil }
        #expect(store.workspaces.map(\.id) == ["ws-1"])
    }

    @Test func addOrUpdateIgnoresChief() async {
        let store = await makeLiveStore(snapshot: [realRow])
        let chief = Workspace(
            id: chiefId,
            title: "Chief of Staff",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil
        )

        store.addOrUpdate(chief)
        #expect(store.workspaces.map(\.id) == ["ws-1"])

        store.handleEvent("subscription.push", params: deltaPush(seq: 1, updated: [realRow]))
        #expect(store.workspaces.map(\.id) == ["ws-1"])
    }
}

@MainActor
struct WorkspaceFetchCompletionTests {
    @Test func concurrentFetchesShareOnlyThePendingOperation() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["workspace.list"]
        let store = WorkspaceStore(connectionManager: connection)
        let first = Task { await store.fetchAll() }
        defer {
            while connection.pendingRequestCount("workspace.list") > 0 {
                connection.failPending("workspace.list", with: CancellationError())
            }
        }
        try await connection.waitForPendingRequests("workspace.list")
        let second = Task { await store.fetchAll() }
        try await expectNever("duplicate workspace request during the shared fetch") {
            connection.paramsForMethod("workspace.list").count > 1
        }
        connection.resolvePending("workspace.list", with: ["workspaces": []])
        await first.value
        await second.value
        #expect(store.lastUpdated != nil)
        connection.pendingMethods = []
        connection.responseMap["workspace.list"] = ["workspaces": []]
        await store.fetchAll()
        #expect(connection.paramsForMethod("workspace.list").count == 2)
    }

    @Test func retryAtLoadingCompletionStartsANewRead() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["workspace.list"]
        let store = WorkspaceStore(connectionManager: connection)
        let first = Task { await store.fetchAll() }
        try await waitUntil("initial fetch pending") { connection.pendingRequestCount("workspace.list") == 1 }
        var retry: Task<Void, Never>?
        withObservationTracking {
            _ = store.isLoading
        } onChange: {
            MainActor.assumeIsolated {
                retry = Task(priority: .high) { await store.fetchAll() }
            }
        }
        connection.pendingMethods = []
        connection.responseMap["workspace.list"] = ["workspaces": [["id": "fresh", "title": "Fresh"]]]
        connection.failPending("workspace.list", with: NSError(domain: "scripted", code: 1))
        await first.value
        await retry?.value
        #expect(connection.requestLog.filter { $0.method == "workspace.list" }.count == 2)
        #expect(store.workspaces.map(\.id) == ["fresh"])
        #expect(store.lastUpdated != nil)
    }
}
