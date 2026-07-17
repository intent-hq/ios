import Foundation
import Testing
import Combine
@testable import Intent

/// Store-level integration tests for TaskStore subscribe lifecycle.
@MainActor
struct TaskStoreIntegrationTests {

    @Test func subscribesOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-test", connectionManager: fake)

        fake.requestResponses["task.subscribe"] = ["subscriptionId": "sub-tasks-123"]
        fake.requestResponses["task.list"] = ["tasks": []]

        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.didRequest(method: "task.subscribe"))

        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.tasks.count == 1)
        #expect(store.tasks[0].id == "task-1")
    }

    @Test func appliesContiguousDelta() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-test", connectionManager: fake)

        fake.requestResponses["task.subscribe"] = ["subscriptionId": "sub-tasks-123"]
        fake.requestResponses["task.list"] = ["tasks": []]
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-123",
            kind: .delta,
            seq: 1,
            delta: SubscriptionPush.DeltaPayload(
                added: [["id": "task-2", "title": "Task 2", "status": "in_progress", "updatedAt": "2026-07-17T12:01:00Z"]],
                updated: [],
                removedIds: []
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.tasks.count == 2)
    }

    @Test func gapTriggersResnapshotAndRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-test", connectionManager: fake)

        fake.requestResponses["task.subscribe"] = ["subscriptionId": "sub-tasks-123"]
        fake.requestResponses["task.list"] = ["tasks": []]
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        fake.requestLog.removeAll()

        // Gap: expected seq 1, got seq 5
        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-123",
            kind: .delta,
            seq: 5,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(fake.didRequest(method: "task.unsubscribe"))
        #expect(fake.requestLog.filter { $0.method == "task.subscribe" }.count >= 1)
        #expect(fake.didRequest(method: "task.list"))
    }

    @Test func connectionLossAndReconnect() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-test", connectionManager: fake)

        fake.requestResponses["task.subscribe"] = ["subscriptionId": "sub-tasks-123"]
        fake.requestResponses["task.list"] = ["tasks": []]

        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        fake.requestLog.removeAll()
        fake.simulateDisconnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.didRequest(method: "task.subscribe"))
        #expect(fake.didRequest(method: "task.list"))
    }

    @Test func legacyEventSuppressedWhileLive() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-test", connectionManager: fake)

        fake.requestResponses["task.subscribe"] = ["subscriptionId": "sub-tasks-123"]
        fake.requestResponses["task.list"] = ["tasks": []]
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        fake.requestLog.removeAll()

        // Inject legacy task:updated event
        fake.injectEvent(method: "event", params: [
            "event": ["type": "task:updated", "workspaceId": "ws-test"]
        ])
        try await Task.sleep(nanoseconds: 50_000_000)

        // No refetch (suppressed while live)
        #expect(!fake.didRequest(method: "task.list"))
    }

    @Test func wrongSubscriptionIdDropped() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-test", connectionManager: fake)

        fake.requestResponses["task.subscribe"] = ["subscriptionId": "sub-tasks-correct"]
        fake.requestResponses["task.list"] = ["tasks": []]
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-correct",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Correct", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.tasks.count == 1)
        #expect(store.tasks[0].title == "Correct")

        // Wrong subscriptionId
        fake.injectSubscriptionPush(
            subscriptionId: "sub-tasks-WRONG",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-2", "title": "Wrong", "status": "not_started", "updatedAt": "2026-07-17T12:01:00Z"]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.tasks.count == 1)
        #expect(store.tasks[0].title == "Correct")
    }
}
