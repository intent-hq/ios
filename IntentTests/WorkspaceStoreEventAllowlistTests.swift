import Foundation
@testable import Intent
import Testing

// MARK: - Event allowlist (non-live fallback)

/// Only `workspace:*` types that can change a rendered `Workspace` field or
/// list membership refetch `workspace.list`; a `lastActivity`-only
/// `workspace:updated` delta is patched in place and must not refetch.
@MainActor
struct WorkspaceStoreEventAllowlistTests {
    private func makeWorkspace(id: String, lastActivity: String?) -> Workspace {
        Workspace(
            id: id,
            title: "Test",
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

    private func workspaceEvent(_ type: String, data: [String: Any] = [:]) -> [String: Any] {
        var event: [String: Any] = ["type": type, "workspaceId": "ws-1"]
        if !data.isEmpty { event["data"] = data }
        return ["event": event]
    }

    @Test func allowlistedWorkspaceEventsRefetchWhenNotLive() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": []]

        for type in [
            "workspace:created", "workspace:deleted", "workspace:activity-changed",
            "workspace:displayStatus-changed", "workspace:attention-changed"
        ] {
            fake.clearRequestLog()
            store.handleEvent("events.event", params: workspaceEvent(type))
            try await waitUntil("\(type) refetch of workspace.list") {
                fake.didCallMethod("workspace.list")
            }
        }
    }

    @Test func workspaceUpdatedWithRenderedFieldChangeRefetches() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": []]

        store.handleEvent(
            "events.event",
            params: workspaceEvent(
                "workspace:updated",
                data: [
                    "workspaceId": "ws-1", "changes": ["title": "Renamed"]
                ]
            )
        )
        try await fake.waitForRequests("workspace.list")
    }

    /// A delta that carries `lastActivity` alongside another rendered field
    /// must still refetch: only the `lastActivity`-only case is patch-complete.
    @Test func workspaceUpdatedWithLastActivityAndTitleRefetches() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": []]
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        store.handleEvent(
            "events.event",
            params: workspaceEvent(
                "workspace:updated",
                data: [
                    "workspaceId": "ws-1",
                    "changes": ["lastActivity": "2026-03-01T12:00:00Z", "title": "Renamed"]
                ]
            )
        )
        // A mixed delta must refetch for the title.
        try await fake.waitForRequests("workspace.list")
    }

    @Test func lastActivityOnlyUpdatePatchesInPlaceWithoutRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": []]
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: "2026-03-01T10:00:00Z")]

        store.handleEvent(
            "events.event",
            params: workspaceEvent(
                "workspace:updated",
                data: [
                    "workspaceId": "ws-1", "changes": ["lastActivity": "2026-03-01T12:00:00Z"]
                ]
            )
        )

        #expect(store.workspaces[0].lastActivity == "2026-03-01T12:00:00Z")
        try await expectNever("workspace.list refetch for a lastActivity-only delta") {
            fake.didCallMethod("workspace.list")
        }
    }

    @Test func nonAllowlistedWorkspaceEventsDoNotRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": []]
        store.workspaces = [makeWorkspace(id: "ws-1", lastActivity: nil)]

        for type in [
            "workspace:waiting-changed", "workspace:delete-scheduled", "workspace:delete-cancelled",
            "workspace:opened", "workspace:closed", "workspace:activity",
            "workspace:setup:started", "workspace:setup:completed",
            "workspace:transfer:progress", "workspace:transfer:ready", "workspace:transfer:failed",
            "workspace:tokenUsage-changed", "workspace:context-changed"
        ] {
            store.handleEvent(
                "events.event",
                params: workspaceEvent(
                    type,
                    data: [
                        "workspaceId": "ws-1", "waiting": true
                    ]
                )
            )
        }

        #expect(store.workspaces[0].waiting, "waiting-changed still patches the row in place")
        try await expectNever("workspace.list refetch for non-allowlisted events") {
            fake.didCallMethod("workspace.list")
        }
    }

    /// Mirrors the Note/Task suites: once the `workspace.subscribe` snapshot
    /// makes the store live, an allowlisted event must not refetch — the
    /// `guard !workspaceLive` sits between the in-place patches and the
    /// allowlist switch.
    @Test func allowlistedWorkspaceEventSuppressedWhileLive() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": []]
        fake.responseMap["workspace.subscribe"] = ["subscriptionId": "sub-1"]
        fake.simulateConnect()
        try await waitUntil("workspace.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        fake.deliverSubscriptionPush(
            SubscriptionPush(
                subscriptionId: "sub-1",
                kind: .snapshot,
                seq: 0,
                snapshot: [
                    ["id": "ws-1", "title": "Live"]
                ],
                delta: nil
            )
        )
        try await waitUntil("live snapshot applied") {
            store.workspaces.map(\.id) == ["ws-1"]
        }

        fake.clearRequestLog()
        store.handleEvent("events.event", params: workspaceEvent("workspace:created"))
        try await expectNever("workspace.list refetch while live") {
            fake.didCallMethod("workspace.list")
        }
    }
}
