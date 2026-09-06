import Foundation
import Testing
@testable import Intent

/// All 8 agent lifecycle events (matching cloudlands-fe AGENT_LIFECYCLE_EVENTS)
private let agentLifecycleEventTypes = [
    "agent:started", "agent:completed", "agent:failed", "agent:created",
    "agent:deleted", "agent:idle", "agent:status-changed", "agent:renamed",
]

@MainActor
struct WorkspaceStoreAgentLifecycleTests {

    private func makeWorkspace(id: String, lastActivity: String?) -> Workspace {
        Workspace(
            id: id, title: "Test", branch: nil, baseRef: nil,
            status: nil, activity: nil, displayStatus: nil,
            lastActivity: lastActivity, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil,
            prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil,
            taskStatsCompleted: nil, taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    // MARK: - Agent lifecycle events never bump lastActivity locally
    // (lastActivity is intentd-derived; see docs/protocol/methods/workspace.md)

    @Test(arguments: agentLifecycleEventTypes)
    func agentLifecycleEventLeavesLastActivityUntouched(eventType: String) async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-07-17T10:00:00Z")]

        let event: [String: Any] = [
            "type": eventType,
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])

        #expect(store.workspaces[0].lastActivity == "2026-07-17T10:00:00Z")
    }

    @Test func agentEventForUnknownWorkspaceDoesNotCrash() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:started",
            "workspaceId": "ws-missing",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.workspaces.isEmpty)
    }

    // MARK: - Unknown agent events are logged but don't update state

    @Test func unknownAgentEventLeavesLastActivityUntouched() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-07-17T10:00:00Z")]

        let unknownEvent: [String: Any] = [
            "type": "agent:unknown-future-event",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T13:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": unknownEvent])

        #expect(store.workspaces[0].lastActivity == "2026-07-17T10:00:00Z")
    }

    // MARK: - Subscription.push race condition prevention

    @Test func snapshotPushBeforeSubscriptionIdReturnsIsProcessed() async throws {
        let store = WorkspaceStore(forTesting: true)

        // Initialize reconciler manually (simulates subscribeLiveState's synchronous init)
        await store.setTestReconciler(DeltaReconciler<Workspace>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceStore.parseWorkspace(dict) }
        ))

        // Feed a snapshot push BEFORE workspaceSubscriptionId is set (simulates race)
        let snapshotParams: [String: Any] = [
            "subscriptionId": "sub-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                ["id": "ws-1", "title": "Test Workspace", "lastActivity": "2026-07-17T12:00:00Z"]
            ]
        ]
        store.handleEvent("subscription.push", params: snapshotParams)

        // Verify the snapshot was processed even though subscriptionId wasn't set yet
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].id == "ws-1")
        #expect(store.workspaces[0].title == "Test Workspace")
    }

    // MARK: - addOrUpdate dedupe (workspace.create response vs subscription delta race, #1066)

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
        return [
            "subscriptionId": "sub-123",
            "kind": "delta",
            "seq": seq,
            "delta": ["added": added, "updated": updated, "removedIds": [String]()] as [String: Any]
        ]
    }

    @Test func addOrUpdateAfterDeltaAddedKeepsSingleRow() async throws {
        // Delta beats the workspace.create response (the common case)
        let store = await makeLiveStore(snapshot: [])
        store.handleEvent("subscription.push", params: deltaPush(
            seq: 1,
            added: [["id": "ws-new", "title": "<Untitled>"]]
        ))
        #expect(store.workspaces.count == 1)

        let response = try #require(WorkspaceStore.parseWorkspace(["id": "ws-new", "title": "<Untitled>"]))
        store.addOrUpdate(response)

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces.filter { $0.id == "ws-new" }.count == 1)
    }

    @Test func addOrUpdateBeforeDeltaKeepsSingleRow() async throws {
        // workspace.create response beats the delta
        let store = await makeLiveStore(snapshot: [["id": "ws-1", "title": "Existing"]])

        let response = try #require(WorkspaceStore.parseWorkspace(["id": "ws-new", "title": "<Untitled>"]))
        store.addOrUpdate(response)
        #expect(store.workspaces.count == 2)
        #expect(store.workspaces[0].id == "ws-new")

        store.handleEvent("subscription.push", params: deltaPush(
            seq: 1,
            added: [["id": "ws-new", "title": "<Untitled>"]]
        ))

        #expect(store.workspaces.count == 2)
        #expect(store.workspaces.filter { $0.id == "ws-new" }.count == 1)
    }

    @Test func addOrUpdateSurvivesUnrelatedDelta() async throws {
        // The seeded reconciler entry keeps the manual row across a delta apply
        // that doesn't mention the new workspace
        let store = await makeLiveStore(snapshot: [["id": "ws-1", "title": "Existing"]])

        let response = try #require(WorkspaceStore.parseWorkspace(["id": "ws-new", "title": "<Untitled>"]))
        store.addOrUpdate(response)

        store.handleEvent("subscription.push", params: deltaPush(
            seq: 1,
            updated: [["id": "ws-1", "title": "Existing Renamed"]]
        ))

        #expect(store.workspaces.count == 2)
        #expect(store.workspaces.filter { $0.id == "ws-new" }.count == 1)
        #expect(store.workspaces.first { $0.id == "ws-1" }?.title == "Existing Renamed")
    }

    @Test func addOrUpdatePublishesLastActivityAsReceived() async throws {
        // The workspace.create response is the daemon's row; no local
        // timestamp is layered on top of it
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-new", lastActivity: "2026-07-17T12:00:00Z")]

        let response = try #require(WorkspaceStore.parseWorkspace([
            "id": "ws-new", "title": "<Untitled>", "lastActivity": "2026-07-17T11:00:00Z"
        ]))
        store.addOrUpdate(response)

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].lastActivity == "2026-07-17T11:00:00Z")
    }

    @Test func liveDeltaCarryingLastActivityIsAppliedAsReceived() async throws {
        let store = await makeLiveStore(snapshot: [
            ["id": "ws-1", "title": "Existing", "lastActivity": "2026-07-17T12:00:00Z"]
        ])

        store.handleEvent("subscription.push", params: deltaPush(
            seq: 1,
            updated: [["id": "ws-1", "title": "Existing", "lastActivity": "2026-07-17T11:00:00Z"]]
        ))

        #expect(store.workspaces[0].lastActivity == "2026-07-17T11:00:00Z")
    }

    @Test func addOrUpdateWithoutReconcilerReplacesExistingRow() async throws {
        // Legacy (non-live) mode: no reconciler, upsert still dedupes by id
        let store = WorkspaceStore(forTesting: true)

        let first = try #require(WorkspaceStore.parseWorkspace(["id": "ws-new", "title": "<Untitled>"]))
        store.addOrUpdate(first)
        let second = try #require(WorkspaceStore.parseWorkspace(["id": "ws-new", "title": "Named"]))
        store.addOrUpdate(second)

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].title == "Named")
    }
}
