import Foundation
@testable import Intent
import Testing

/// Workspace list reads under event bursts: one in-flight read, one trailing
/// read for events during it, and a successor for events during that.
@MainActor
struct WorkspaceFetchCoalescingTests {
    private func rows(_ ids: String...) -> [String: Any] {
        ["workspaces": ids.map { ["id": $0, "title": $0] }]
    }

    private func refetchEvent(_ store: WorkspaceStore) {
        store.handleEvent("events.event", params: [
            "event": ["type": "workspace:created", "workspaceId": "ws-new", "data": ["workspaceId": "ws-new"]]
        ])
    }

    private func listCount(_ connection: FakeConnectionManager) -> Int {
        connection.paramsForMethod("workspace.list").count
    }

    @Test func eventsDuringAReadCollapseIntoOneTrailingRead() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["workspace.list"]
        let store = WorkspaceStore(connectionManager: connection)
        let fetch = Task { await store.fetchAll() }
        try await connection.waitForPendingRequests("workspace.list")
        for _ in 0..<3 { refetchEvent(store) }
        try await expectNever("a second read while the first is in flight") { listCount(connection) > 1 }
        connection.resolvePending("workspace.list", with: rows("stale"))
        try await connection.waitForPendingRequests("workspace.list")
        #expect(store.lastUpdated == nil, "an invalidated read must not publish")
        connection.resolvePending("workspace.list", with: rows("fresh"))
        await fetch.value
        try await expectNever("a third read after the burst settled") { listCount(connection) > 2 }
        #expect(store.workspaces.map(\.id) == ["fresh"])
        #expect(!store.isLoading)
    }

    @Test func eventDuringTheTrailingReadHandsOffToOneSuccessor() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["workspace.list"]
        let store = WorkspaceStore(connectionManager: connection)
        let fetch = Task { await store.fetchAll() }
        try await connection.waitForPendingRequests("workspace.list")
        refetchEvent(store)
        connection.resolvePending("workspace.list", with: rows("stale-1"))
        try await connection.waitForPendingRequests("workspace.list")
        refetchEvent(store)
        connection.resolvePending("workspace.list", with: rows("stale-2"))
        await fetch.value
        #expect(store.isLoading, "the successor keeps the list loading")
        #expect(store.lastUpdated == nil)
        try await connection.waitForPendingRequests("workspace.list")
        connection.resolvePending("workspace.list", with: rows("fresh"))
        try await waitUntil("successor published") { store.workspaces.map(\.id) == ["fresh"] && !store.isLoading }
        try await expectNever("another read after the successor settled") { listCount(connection) > 3 }
    }

    @Test func fetchIfNeededReadsOnlyWhileTheListIsStale() async throws {
        let connection = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: connection)
        store.publishFetchedWorkspaces([])
        await store.fetchIfNeeded()
        #expect(listCount(connection) == 0, "a live snapshot counts as fresh")

        connection.responseMap["workspace.list"] = rows("a")
        refetchEvent(store)
        try await waitUntil("event read published") { store.workspaces.map(\.id) == ["a"] && !store.isLoading }
        await store.fetchIfNeeded()
        #expect(listCount(connection) == 1)

        connection.errorMap["workspace.list"] = NSError(domain: "scripted", code: 1)
        await store.fetchAll()
        #expect(listCount(connection) == 2)
        connection.errorMap["workspace.list"] = nil
        connection.responseMap["workspace.list"] = rows("b")
        await store.fetchIfNeeded()
        #expect(listCount(connection) == 3, "a failed read stays dirty")
        #expect(store.workspaces.map(\.id) == ["b"])
        await store.fetchIfNeeded()
        #expect(listCount(connection) == 3)
    }
}
