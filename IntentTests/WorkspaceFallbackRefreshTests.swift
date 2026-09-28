import Foundation
@testable import Intent
import Testing

extension WorkspaceFetchCompletionTests {
    @Test(arguments: [false, true])
    func fallbackEventsDuringReadReconcileOnce(failedRead: Bool) async throws {
        let (store, connection) = try await fallbackStore()
        defer { drainWorkspaceReads(connection) }
        connection.pendingMethods = ["workspace.list"]
        let checkpoint = connection.checkpoint
        workspaceRename(connection, "First rename")
        try await connection.waitForPendingRequests("workspace.list")
        let passive = Task { await store.fetchAll() }
        for _ in 0..<20 { workspaceRename(connection, "Second rename") }
        try await expectNever("parallel fallback refresh") { connection.traffic(since: checkpoint).requests.count > 1 }
        if failedRead {
            connection.failPending("workspace.list", with: URLError(.networkConnectionLost))
        } else {
            connection.resolvePending("workspace.list", with: workspaceReply("First rename"))
        }
        try await waitUntil("one trailing fallback read") {
            connection.traffic(since: checkpoint).requests.count == 2 && connection.pendingRequestCount("workspace.list") == 1
        }
        #expect(store.isLoading)
        #expect(store.workspaces.first?.title == "Initial title")
        connection.resolvePending("workspace.list", with: workspaceReply("Second rename"))
        await passive.value
        try await waitUntil("latest workspace title") { !store.isLoading && store.workspaces.first?.title == "Second rename" }
        #expect(connection.traffic(since: checkpoint).methodCounts == ["workspace.list": 2])
        printCatalogLedger("workspace-fallback-burst-failed-\(failedRead)", connection.traffic(since: checkpoint))
    }

    @Test(arguments: [false, true])
    func invalidatedTrailingWorkspaceReadRemainsDirty(failedRead: Bool) async throws {
        let (store, connection) = try await fallbackStore()
        defer { drainWorkspaceReads(connection) }
        connection.pendingMethods = ["workspace.list"]
        let checkpoint = connection.checkpoint
        let first = Task { await store.fetchAll() }
        try await connection.waitForPendingRequests("workspace.list")
        workspaceRename(connection, "First rename")
        try await expectNever("parallel initial reconciliation") { connection.traffic(since: checkpoint).requests.count > 1 }
        connection.resolvePending("workspace.list", with: workspaceReply("Initial title"))
        try await waitUntil("held trailing read") {
            connection.traffic(since: checkpoint).requests.count == 2 && connection.pendingRequestCount("workspace.list") == 1
        }
        for _ in 0..<20 { workspaceRename(connection, "Latest rename") }
        try await expectNever("parallel trailing reconciliation") { connection.traffic(since: checkpoint).requests.count > 2 }
        if failedRead {
            connection.failPending("workspace.list", with: URLError(.networkConnectionLost))
        } else {
            connection.resolvePending("workspace.list", with: workspaceReply("First rename"))
        }
        await first.value
        #expect(!store.isLoading)
        #expect(store.workspaces.first?.title == "Initial title")
        try await expectNever("unbounded workspace refresh loop") { connection.traffic(since: checkpoint).requests.count > 2 }
        printCatalogLedger("workspace-invalidated-trailing-failed-\(failedRead)", connection.traffic(since: checkpoint))
        let retryCheckpoint = connection.checkpoint
        let retry = Task { await store.fetchIfNeeded() }
        try await connection.waitForPendingRequests("workspace.list")
        let joined = Task { await store.fetchIfNeeded() }
        try await expectNever("parallel dirty retry") { connection.traffic(since: retryCheckpoint).requests.count > 1 }
        connection.resolvePending("workspace.list", with: workspaceReply("Latest rename"))
        await retry.value
        await joined.value
        #expect(store.workspaces.first?.title == "Latest rename")
        #expect(connection.traffic(since: retryCheckpoint).methodCounts == ["workspace.list": 1])
        await store.fetchIfNeeded()
        #expect(connection.traffic(since: retryCheckpoint).requests.count == 1)
        printCatalogLedger("workspace-dirty-retry-failed-\(failedRead)", connection.traffic(since: retryCheckpoint))
    }

    @Test func failedWorkspaceRefreshIsRetryableWithoutAnotherEvent() async throws {
        let (store, connection) = try await fallbackStore()
        connection.errorMap["workspace.list"] = URLError(.networkConnectionLost)
        let checkpoint = connection.checkpoint
        await store.fetchAll()
        #expect(store.workspaces.first?.title == "Initial title")
        connection.errorMap["workspace.list"] = nil
        connection.responseMap["workspace.list"] = workspaceReply("Recovered")
        await store.fetchIfNeeded()
        #expect(store.workspaces.first?.title == "Recovered")
        #expect(connection.traffic(since: checkpoint).methodCounts == ["workspace.list": 2])
        printCatalogLedger("workspace-failed-refresh-retry", connection.traffic(since: checkpoint))
    }

    @Test func liveWorkspaceEventsDoNotDirtyPassiveFetches() async throws {
        let connection = RPCRecordingConnection()
        connection.responseMap["workspace.list"] = workspaceReply("Live title")
        connection.responseMap["workspace.subscribe"] = ["subscriptionId": "workspace-live"]
        let store = WorkspaceStore(connectionManager: connection)
        connection.simulateConnect()
        try await waitUntil("workspace live handler") { connection.hasSubscriptionHandler(id: "workspace-live") }
        connection.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "workspace-live",
            kind: .snapshot,
            seq: 0,
            snapshot: [["id": "workspace", "title": "Live title"]],
            delta: nil
        ))
        let checkpoint = connection.checkpoint
        workspaceRename(connection, "Waiting for live delta")
        try await expectNever("live event list read") { !connection.traffic(since: checkpoint).requests.isEmpty }
        connection.pendingMethods = ["workspace.list"]
        defer { drainWorkspaceReads(connection) }
        let first = Task { await store.fetchAll() }
        try await connection.waitForPendingRequests("workspace.list")
        let second = Task { await store.fetchAll() }
        workspaceRename(connection, "Still waiting for live delta")
        try await expectNever("parallel live passive read") { connection.traffic(since: checkpoint).requests.count > 1 }
        connection.resolvePending("workspace.list", with: workspaceReply("Live title"))
        await first.value
        await second.value
        await store.fetchIfNeeded()
        #expect(connection.traffic(since: checkpoint).methodCounts == ["workspace.list": 1])
        #expect(store.workspaces.first?.title == "Live title")
        printCatalogLedger("workspace-live-passive-control", connection.traffic(since: checkpoint))
    }

    private func fallbackStore() async throws -> (WorkspaceStore, RPCRecordingConnection) {
        let connection = RPCRecordingConnection()
        connection.responseMap["workspace.list"] = workspaceReply("Initial title")
        let methodNotFound = -32_601
        connection.errorMap["workspace.subscribe"] = NSError(domain: "WebSocket", code: methodNotFound)
        let store = WorkspaceStore(connectionManager: connection)
        connection.simulateConnect()
        try await waitUntil("unsupported live workspace subscription") {
            store.workspaces.first?.title == "Initial title" && connection.traffic().calls("workspace.subscribe").count == 1
                && connection.traffic().pendingCount == 0
        }
        return (store, connection)
    }

    private func workspaceReply(_ title: String) -> [String: Any] {
        ["workspaces": [["id": "workspace", "title": title]]]
    }

    private func workspaceRename(_ connection: RPCRecordingConnection, _ title: String) {
        connection.deliverEvent(method: "event", params: [
            "event": ["type": "workspace:updated", "workspaceId": "workspace", "data": ["changes": ["title": title]]]
        ])
    }

    private func drainWorkspaceReads(_ connection: RPCRecordingConnection) {
        while connection.pendingRequestCount("workspace.list") > 0 {
            connection.failPending("workspace.list", with: CancellationError())
        }
    }
}
