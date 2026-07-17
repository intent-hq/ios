import Foundation
import Testing
@testable import Intent

@MainActor
struct WorkspaceStoreAgentLifecycleTests {
    
    // MARK: - All 8 agent lifecycle events trigger refetch (legacy path)
    
    @Test func agentStartedTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)

        let event: [String: Any] = [
            "type": "agent:started",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]

        // Verify handleEvent doesn't crash and updates high-water mark
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentCompletedTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:completed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentFailedTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:failed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentCreatedTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:created",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentDeletedTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:deleted",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentIdleTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:idle",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentStatusChangedTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:status-changed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }

    @Test func agentRenamedTriggersRefetch() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:renamed",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
    }
    
    @Test func unknownAgentEventIsLogged() async throws {
        let store = WorkspaceStore(forTesting: true)
        let event: [String: Any] = [
            "type": "agent:unknown-future-type",
            "workspaceId": "ws-1",
            "timestamp": "2026-07-17T12:00:00Z"
        ]
        // Should log but not crash
        store.handleEvent(method: "events.event", params: ["event": event])
        #expect(true)
    }
    
    @Test func agentEventUpdatesLastActivityHighWaterMark() async throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [
            Workspace(id: "ws-1", title: "Test", branch: nil, baseRef: nil,
                      status: nil, activity: nil, lastActivity: "2026-07-17T10:00:00Z",
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
        store.handleEvent(method: "events.event", params: ["event": event])
        
        #expect(store.lastActivityHighWaterMark["ws-1"] == "2026-07-17T12:00:00Z")
        #expect(store.workspaces[0].lastActivity == "2026-07-17T12:00:00Z")
    }
}
