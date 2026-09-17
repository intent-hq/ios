import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

/// Integration tests for the workspace-keyed monitor pool feeding the list
/// rows (one global prMonitor:* subscription, per-workspace seed + fold).
@MainActor
struct WorkspacePrMonitorsStoreTests {
    private func makeMonitorDict(
        monitorId: String = "prm-1",
        workspaceId: String = "ws-abc",
        prNumber: Int = 12,
        state: String = "active"
    ) -> [String: Any] {
        [
            "monitorId": monitorId,
            "workspaceId": workspaceId,
            "agentId": "agent-1",
            "repo": "octo/repo",
            "prNumber": prNumber,
            "state": state,
            "pendingChanges": [] as [String],
            "hasPendingChanges": false,
            "createdAt": "2026-08-07T11:58:00.000Z",
            "updatedAt": "2026-08-07T11:58:00.000Z"
        ]
    }

    private func makeEventData(
        monitorId: String = "prm-1",
        workspaceId: String = "ws-abc",
        state: String = "active"
    ) -> [String: Any] {
        [
            "workspaceId": workspaceId,
            "agentId": "agent-1",
            "monitorId": monitorId,
            "repo": "octo/repo",
            "prNumber": 12,
            "state": state
        ]
    }

    private func makeSeededStore(
        _ fake: FakeConnectionManager,
        monitors: [[String: Any]] = [],
        workspaceId: String = "ws-abc"
    ) async -> WorkspacePrMonitorsStore {
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-rows"]
        fake.responseMap["prMonitor.list"] = ["monitors": monitors]
        let store = WorkspacePrMonitorsStore(connectionManager: fake)
        await store.seed(workspaceId: workspaceId)
        return store
    }

    @Test func seedSubscribesGloballyAndListsWorkspace() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])

        let subscribeParams = try #require(fake.paramsForMethod("events.subscribe").first)
        #expect(subscribeParams["eventTypes"] as? [String] == ["prMonitor:*"])
        // Global subscription: no workspace filter, one rows-wide group.
        #expect(subscribeParams["workspaceId"] == nil)
        #expect(subscribeParams["replaceGroup"] as? String == "ios-pr-monitors-rows")
        #expect(fake.paramsForMethod("prMonitor.list").first?["workspaceId"] as? String == "ws-abc")
        #expect(store.monitors(for: "ws-abc").count == 1)
        #expect(store.monitors(for: "ws-other").isEmpty)
    }

    @Test func repeatSeedIsNoOpAndSecondWorkspaceGetsOwnBucket() async {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])
        fake.clearRequestLog()

        await store.seed(workspaceId: "ws-abc")
        #expect(fake.paramsForMethod("prMonitor.list").isEmpty)
        #expect(fake.paramsForMethod("events.subscribe").isEmpty)

        fake.responseMap["prMonitor.list"] = [
            "monitors": [
                makeMonitorDict(monitorId: "prm-9", workspaceId: "ws-def", prNumber: 9)
            ]
        ]
        await store.seed(workspaceId: "ws-def")
        #expect(fake.paramsForMethod("prMonitor.list").first?["workspaceId"] as? String == "ws-def")
        // One global subscription serves both workspaces.
        #expect(fake.paramsForMethod("events.subscribe").isEmpty)
        #expect(store.monitors(for: "ws-abc").count == 1)
        #expect(store.monitors(for: "ws-def").count == 1)
    }

    @Test func wrappedEventFoldsIntoWorkspaceBucket() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-rows",
            "event": [
                "type": "prMonitor:completed",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "completed")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.monitors(for: "ws-abc")[0].state == .completed)
    }

    @Test func monitorEventsInvalidateObservedWorkspaceBucket() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.monitors(for: "ws-abc")
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-rows",
            "event": [
                "type": "prMonitor:completed",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "completed")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(changeCount.withLock { $0 } == 1)
        #expect(store.monitors(for: "ws-abc")[0].state == .completed)
    }

    @Test func eventForUnseededWorkspaceIsIgnored() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])
        fake.clearRequestLog()

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-rows",
            "event": [
                "type": "prMonitor:registered",
                "workspaceId": "ws-unseen",
                "data": makeEventData(monitorId: "prm-x", workspaceId: "ws-unseen")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)

        // No bucket, no refetch for a workspace no row has seeded.
        #expect(store.monitors(for: "ws-unseen").isEmpty)
        #expect(fake.paramsForMethod("prMonitor.list").isEmpty)
    }

    @Test func foreignSubscriptionEventIsIgnored() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-foreign",
            "event": [
                "type": "prMonitor:cancelled",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "cancelled")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.monitors(for: "ws-abc").count == 1)
    }

    @Test func cancelledEventDropsMonitorFromBucket() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-rows",
            "event": [
                "type": "prMonitor:cancelled",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "cancelled")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.monitors(for: "ws-abc").isEmpty)
    }

    @Test func unknownMonitorEventRefetchesOnlyItsWorkspace() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake)
        fake.responseMap["prMonitor.list"] = ["monitors": [] as [[String: Any]]]
        await store.seed(workspaceId: "ws-def")
        fake.clearRequestLog()
        fake.responseMap["prMonitor.list"] = [
            "monitors": [
                makeMonitorDict(monitorId: "prm-new", workspaceId: "ws-def")
            ]
        ]

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-rows",
            "event": [
                "type": "prMonitor:registered",
                "workspaceId": "ws-def",
                "data": makeEventData(monitorId: "prm-new", workspaceId: "ws-def")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 100_000_000)

        let listCalls = fake.paramsForMethod("prMonitor.list")
        #expect(listCalls.count == 1)
        #expect(listCalls.first?["workspaceId"] as? String == "ws-def")
        #expect(store.monitors(for: "ws-def").count == 1)
        #expect(store.monitors(for: "ws-def")[0].monitorId == "prm-new")
    }

    @Test func reconnectResubscribesAndReseedsAllWorkspaces() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])
        fake.responseMap["prMonitor.list"] = ["monitors": [] as [[String: Any]]]
        await store.seed(workspaceId: "ws-def")
        fake.clearRequestLog()
        fake.responseMap["prMonitor.list"] = ["monitors": [makeMonitorDict()]]

        fake.simulateDisconnect()
        fake.simulateConnect()
        await Task.yield()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if fake.paramsForMethod("prMonitor.list").count >= 2 { break }
        }

        #expect(fake.didCallMethod("events.subscribe"))
        let reseededIds = Set(fake.paramsForMethod("prMonitor.list")
            .compactMap { $0["workspaceId"] as? String })
        #expect(reseededIds == ["ws-abc", "ws-def"])
    }

    @Test func staleListResponseAfterCancelledFoldIsDiscarded() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSeededStore(fake, monitors: [makeMonitorDict()])
        fake.clearRequestLog()

        // Suspend prMonitor.list so a fold can land while one is in flight.
        fake.pendingMethods.insert("prMonitor.list")
        let refetchTask = Task { await store.refetch(workspaceId: "ws-abc") }
        try await Task.sleep(nanoseconds: 20_000_000)

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-rows",
            "event": [
                "type": "prMonitor:cancelled",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "cancelled")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(store.monitors(for: "ws-abc").isEmpty)

        // Resolve the in-flight request with the STALE payload — it still
        // lists the cancelled monitor.
        fake.resolvePending("prMonitor.list", with: ["monitors": [makeMonitorDict()]])
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(store.monitors(for: "ws-abc").isEmpty)
        #expect(fake.paramsForMethod("prMonitor.list").count == 2)

        // Fresh server state (post-cancel) for the queued follow-up fetch.
        fake.resolvePending("prMonitor.list", with: ["monitors": [] as [[String: Any]]])
        await refetchTask.value
        #expect(store.monitors(for: "ws-abc").isEmpty)
    }

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: WorkspacePrMonitorsStore? = await makeSeededStore(fake)
        #expect(fake.eventHandlerCount == 1)
        #expect(store != nil)

        store = nil
        for _ in 0..<40 {
            if fake.eventHandlerCount == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fake.eventHandlerCount == 0)
    }
}
