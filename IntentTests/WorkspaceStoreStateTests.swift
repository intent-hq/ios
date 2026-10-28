import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

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
            agentSummaryCount: nil
        )
    }

    @Test func parseWorkspaceDecodesAttention() {
        let workspace = WorkspaceStore.parseWorkspace(
            ["id": "ws-1", "title": "T", "attention": "unread"]
        )
        #expect(workspace?.attention == "unread")
    }

    @Test func clearUnreadAttentionLocallyClearsUnread() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].attention == "none")
    }

    @Test func clearUnreadAttentionLocallyGuardedOnUnread() {
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

    @Test func clearUnreadAttentionLocallyUnknownWorkspaceIsNoOp() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-other")
        #expect(store.workspaces[0].attention == "unread")
    }

    @Test func attentionSurvivesLastActivityRebuild() {
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
            agentSummaryCount: nil
        )
    }

    @Test func updateWaitingSetsAndClearsFlag() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]

        store.updateWaiting(workspaceId: "ws-1", waiting: true)
        #expect(store.workspaces[0].waiting == true)

        store.updateWaiting(workspaceId: "ws-1", waiting: false)
        #expect(store.workspaces[0].waiting == false)
    }

    @Test func updateWaitingUnknownWorkspaceIsNoOp() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]
        store.updateWaiting(workspaceId: "ws-other", waiting: true)
        #expect(store.workspaces[0].waiting == false)
    }

    @Test func waitingChangedEventPatchesRowInPlace() {
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

    @Test func waitingChangedEventLeavesOtherWorkspacesUntouched() {
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

    @Test func waitingChangedEventFallsBackToEnvelopeWorkspaceId() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1")]

        store.handleEvent("event", params: [
            "event": [
                "type": "workspace:waiting-changed",
                "workspaceId": "ws-1",
                "data": ["waiting": true]
            ] as [String: Any]
        ] as [String: Any])

        #expect(store.workspaces[0].waiting == true)
    }

    @Test func waitingSurvivesLastActivityRebuild() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true)]
        store.updateLastActivity(workspaceId: "ws-1", lastActivity: "2026-03-01T12:00:00Z")
        #expect(
            store.workspaces[0].waiting == true,
            "The lastActivity rebuild must carry the waiting flag through"
        )
    }

    @Test func waitingSurvivesClearUnreadAttention() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [makeWorkspace(id: "ws-1", waiting: true, attention: "unread")]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].attention == "none")
        #expect(
            store.workspaces[0].waiting == true,
            "Clearing unread must not drop the waiting flag"
        )
    }

    @Test func fullRowRefreshDropsWaitingWhenOmitted() throws {
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
        enum ObservationState {
            case observed(Bool)
            case pending
        }

        let store = WorkspaceStore(forTesting: true)
        let observedLastUpdated = Mutex(ObservationState.pending)
        withObservationTracking {
            _ = store.workspaces
        } onChange: {
            MainActor.assumeIsolated {
                observedLastUpdated.withLock { lastUpdatedWasObserved in
                    lastUpdatedWasObserved = .observed(store.lastUpdated != nil)
                }
            }
        }
        let workspace = try #require(WorkspaceStore.parseWorkspace(["id": "ws-observed", "title": "Observed"]))
        store.publishFetchedWorkspaces([workspace])

        #expect(
            observedLastUpdated.withLock { state in
                if case .observed(true) = state { return true }
                return false
            },
            "lastUpdated must already be set when workspaces invalidates"
        )
        #expect(store.workspaces.map(\.id) == ["ws-observed"])
    }

    @Test func publishFetchedWorkspaces_updatesWorkspacesAndLastUpdated() throws {
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
