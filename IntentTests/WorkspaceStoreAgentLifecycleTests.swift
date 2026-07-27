import Foundation
import Testing
@testable import Intent

@MainActor
struct WorkspaceStoreAgentLifecycleTests {

    // MARK: - All 8 agent lifecycle events update high-water mark
    
    @Test func agentStartedUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)

        let event: [String: Any] = [
            "type": "agent:started",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]

        // Verify handleEvent doesn't crash and updates high-water mark
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentCompletedUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:completed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentFailedUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:failed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentCreatedUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:created",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentDeletedUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:deleted",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentIdleUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:idle",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentStatusChangedUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:status-changed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentRenamedUpdatesHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:renamed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    // MARK: - Unknown agent events are logged but don't update state

    @Test func unknownAgentEventDoesNotUpdateHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)

        // Seed with a known event first
        let knownEvent: [String: Any] = [
            "type": "agent:started",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": knownEvent])
        let initialMark = store.lastActivityHighWaterMark["ws-1"]

        // Feed unknown event
        let unknownEvent: [String: Any] = [
            "type": "agent:unknown-future-event",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T13:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": unknownEvent])

        // High-water mark should be unchanged
        #expect(store.lastActivityHighWaterMark["ws-1"] == initialMark)
    }
    
    @Test func agentEventUpdatesLastActivityHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [
            Workspace(id: "ws-1", title: "Test", branch: nil, baseRef: nil,
                      status: nil, activity: nil, displayStatus: nil,
                      lastActivity: "2026-07-17T10:00:00Z",
                      updatedAt: nil, repositoryOwner: nil, repositoryName: nil,
                      prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil,
                      taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil,
                      agentSummaryCount: nil, agentSummaryAgents: nil)
        ]
        
        let event: [String: Any] = [
            "type": "agent:started",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent("events.event", params: ["event": event])

        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
        #expect(store.workspaces[0].lastActivity == "2026-07-17T12:00:00Z")
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
}
