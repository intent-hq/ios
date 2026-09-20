import Combine
import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

@MainActor
struct TaskStoreIntegrationTests {
    @Test func fetchedTasksRemainObservable() async {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = [
            "tasks": [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        ]
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.tasks.count
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }

        await store.fetchAll()

        #expect(changeCount.withLock { $0 } == 1)
        #expect(store.tasks.count == 1)
    }

    // MARK: - subscribeOnConnect

    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)

        // Configure responses
        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseMap["task.subscribe"] = [
            "subscriptionId": "sub-1",
            "seq": 0,
            "snapshot": []
        ]

        // Start connected
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Verify subscribe was called
        #expect(fake.didCallMethod("task.subscribe"))

        // Deliver snapshot push to make the store live (applied synchronously)
        let push = SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        )
        fake.deliverSubscriptionPush(push)

        // Verify state
        #expect(store.tasks.count == 1)
    }

    // MARK: - contiguousDeltaAdvancesState

    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)

        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        ))
        #expect(store.tasks.count == 1)

        // Contiguous delta
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 1,
            delta: SubscriptionPush.DeltaPayload(
                added: [["id": "task-2", "title": "Task 2", "status": "in_progress", "updatedAt": "2024-01-02T00:00:00Z"]],
                updated: [],
                removedIds: []
            )
        ))

        #expect(store.tasks.count == 2)
    }

    // MARK: - gapTriggersResnapshotWithBaselineRefetch

    @Test func gapTriggersResnapshotWithBaselineRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)

        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["task.unsubscribe"] = ["ok": true]
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        ))
        #expect(store.tasks.count == 1)

        fake.clearRequestLog()

        // Gap (seq 5 instead of 1) triggers resnapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 5,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        ))
        // The baseline `task.list` is the last step of resnapshot, so its
        // arrival proves unsubscribe and subscribe already ran.
        try await fake.waitForRequests("task.list")

        // Verify resnapshot: unsubscribe, subscribe, list
        #expect(fake.didCallMethod("task.unsubscribe"))
        #expect(fake.didCallMethod("task.subscribe"))
        #expect(fake.didCallMethod("task.list"))
        withExtendedLifetime(store) {}
    }

    // MARK: - connectionLossClearsLiveThenReconnectResubscribes

    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)

        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        ))
        #expect(store.tasks.count == 1)

        // Disconnect, then reconnect with a fresh subscription id so the
        // resubscribe is distinguishable from the original registration.
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-2", "seq": 0, "snapshot": []]
        fake.clearRequestLog()
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("reconnect resubscribe") {
            fake.hasSubscriptionHandler(id: "sub-2")
        }

        // Verify fresh subscribe + list
        #expect(fake.didCallMethod("task.subscribe"))
        #expect(fake.didCallMethod("task.list"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - legacyEventSuppressedWhileLive

    @Test func legacyEventSuppressedWhileLive() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)

        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot establishes live state
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        ))
        #expect(store.tasks.count == 1)

        fake.clearRequestLog()

        // Deliver an allowlisted legacy event: only the live guard can suppress
        // it, so the test proves live-mode suppression rather than the allowlist.
        fake.deliverEvent(method: "events.event", params: [
            "event": [
                "type": "task:status-changed",
                "workspaceId": "ws-1",
                "noteId": "task-1"
            ]
        ])

        // Verify no refetch (live guard suppressed the allowlisted event)
        try await expectNever("task.list refetch while live") {
            fake.didCallMethod("task.list")
        }
    }

    // MARK: - crossIdPushIsolation

    @Test func crossIdPushIsolation() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)

        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-A")
        }

        // Snapshot for sub-A
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-A",
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        ))
        #expect(store.tasks.count == 1)

        // Push for unregistered sub-B (should be ignored by store)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-B",
            seq: 0,
            snapshot: [
                ["id": "task-99", "title": "Should not appear", "status": "in_progress", "updatedAt": "2024-01-01T00:00:00Z"]
            ]
        ))

        // Verify state unchanged
        #expect(store.tasks.count == 1)
        #expect(store.tasks[0].id == "task-1")
        #expect(!fake.hasSubscriptionHandler(id: "sub-B"))
    }

    // MARK: - deinit removes event + subscription handlers (monorepo#2211, monorepo#2213)

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: TaskStore? = TaskStore(workspaceId: "ws-1", connectionManager: fake)

        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }
        #expect(fake.eventHandlerCount == 1)
        #expect(fake.subscriptionHandlerCount == 1)
        #expect(store != nil)

        store = nil
        // deinit hops to the main actor to remove the handlers; wait for that task
        try await waitUntil("deinit to remove event + subscription handlers") {
            fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }

    // MARK: - Event allowlist (non-live fallback)

    private func taskEvent(_ type: String, workspaceId: String = "ws-1") -> [String: Any] {
        ["event": ["type": type, "workspaceId": workspaceId, "noteId": "task-1"] as [String: Any]]
    }

    @Test func allowlistedTaskEventsRefetchWhenNotLive() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": []]

        for type in ["task:created", "task:status-changed"] {
            fake.clearRequestLog()
            store.handleEvent("events.event", params: taskEvent(type))
            try await fake.waitForRequests("task.list")
            #expect(fake.didCallMethod("task.list"), "\(type) must refetch task.list")
        }
    }

    @Test func nonAllowlistedTaskEventsDoNotRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": []]

        for type in ["task:ready-tasks-changed", "task:agent-linked", "task:agent-unlinked", "task:updated"] {
            store.handleEvent("events.event", params: taskEvent(type))
        }

        try await expectNever("task.list refetch for non-allowlisted events") {
            fake.didCallMethod("task.list")
        }
    }

    /// intentd's `delete_note` emits `task:ready-tasks-changed` with
    /// `data.triggeredBy.reason == "note-deleted"` and no other `task:*` type,
    /// so that emission is the only signal that a task row left the list.
    private func readyTasksChangedEvent(triggeredBy: [String: Any]) -> [String: Any] {
        [
            "event": [
                "type": "task:ready-tasks-changed",
                "workspaceId": "ws-1",
                "data": [
                    "readyTaskIds": ["task-2"],
                    "triggeredBy": triggeredBy,
                    "computedAt": "2026-03-01T10:00:00Z"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    @Test func readyTasksChangedForDeletedNoteRefetchesWhenNotLive() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": []]

        store.handleEvent("events.event", params: readyTasksChangedEvent(
            triggeredBy: ["noteId": "task-1", "reason": "note-deleted"]
        ))

        try await fake.waitForRequests("task.list")
        #expect(fake.didCallMethod("task.list"))
    }

    @Test func readyTasksChangedForOtherReasonsDoesNotRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": []]

        store.handleEvent("events.event", params: readyTasksChangedEvent(
            triggeredBy: ["noteId": "task-1", "reason": "relations-changed"]
        ))
        store.handleEvent("events.event", params: readyTasksChangedEvent(
            triggeredBy: ["noteId": "task-1", "previousStatus": "not_started", "newStatus": "complete"]
        ))

        try await expectNever("task.list refetch for non-deletion ready-tasks-changed") {
            fake.didCallMethod("task.list")
        }
    }

    @Test func allowlistedTaskEventForOtherWorkspaceDoesNotRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": []]

        store.handleEvent("events.event", params: taskEvent("task:status-changed", workspaceId: "ws-other"))

        try await expectNever("task.list refetch for another workspace's event") {
            fake.didCallMethod("task.list")
        }
    }
}
