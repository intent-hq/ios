import Foundation
@testable import Intent
import Testing

/// Store-level races around `LiveSubscription`: the handler registrations a
/// store makes and releases when a reconnect, a teardown or a repeated ack
/// lands in the middle of a subscribe or resnapshot.
@MainActor
struct LiveSubscriptionStoreTests {
    private func taskSnapshot(_ subscriptionId: String) -> SubscriptionPush {
        SubscriptionPush(subscriptionId: subscriptionId, seq: 0, snapshot: [
            ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2024-01-01T00:00:00Z"]
        ])
    }

    private func gap(_ subscriptionId: String) -> SubscriptionPush {
        SubscriptionPush(
            subscriptionId: subscriptionId,
            seq: 5,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        )
    }

    @Test func reconnectDuringResnapshotEndsTheRepairAndLaterGapsStillRecover() async throws {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": []]
        fake.responseQueueMap["task.subscribe"] = ["sub-1", "sub-2", "sub-3", "sub-4"].map { ["subscriptionId": $0] }
        fake.simulateConnect()
        try await waitUntil("first subscription") { fake.hasSubscriptionHandler(id: "sub-1") }
        fake.deliverSubscriptionPush(taskSnapshot("sub-1"))
        #expect(store.tasks.count == 1)

        // A gap starts a resnapshot that parks on its unsubscribe.
        fake.pendingMethods = ["task.unsubscribe"]
        fake.deliverSubscriptionPush(gap("sub-1"))
        try await fake.waitForPendingRequests("task.unsubscribe")
        #expect(fake.unregisteredSubscriptionIds == ["sub-1"])

        // The reconnect tears down (the old id is still held) and resubscribes.
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("reconnect subscription") { fake.hasSubscriptionHandler(id: "sub-2") }
        #expect(fake.unregisteredSubscriptionIds == ["sub-1", "sub-1"])

        // The parked pre-reconnect resnapshot finishes its unsubscribe and sees
        // that the connection generation advanced, so it does NOT open a
        // duplicate subscription over the new connection.
        fake.pendingMethods = []
        fake.resolvePending("task.unsubscribe", with: ["ok": true])
        try await expectNever("superseded resnapshot subscribing again", within: .milliseconds(150)) {
            fake.hasSubscriptionHandler(id: "sub-3")
        }
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))

        // The reconnect cleared the resnapshot guard: the next gap recovers again.
        fake.deliverSubscriptionPush(taskSnapshot("sub-2"))
        fake.responseMap["task.unsubscribe"] = ["ok": true]
        fake.deliverSubscriptionPush(gap("sub-2"))
        try await waitUntil("recovery after the reconnect") { fake.hasSubscriptionHandler(id: "sub-3") }
        #expect(fake.unregisteredSubscriptionIds == ["sub-1", "sub-1", "sub-2"])
        #expect(fake.paramsForMethod("task.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-1", "sub-2"])
    }

    @Test func teardownWhileSubscribingReleasesLateAckWithoutRegisteringIt() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.pendingMethods = ["comment.subscribe"]

        let subscribing = Task { await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1") }
        try await fake.waitForPendingRequests("comment.subscribe")
        await store.unsubscribeFromCurrentNote()
        #expect(fake.unregisteredSubscriptionIds.isEmpty, "Nothing was acknowledged yet")

        fake.pendingMethods = []
        fake.resolvePending("comment.subscribe", with: ["subscriptionId": "sub-1"])
        await subscribing.value
        // The superseded ack is immediately released daemon-side and never registered locally.
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
        #expect(fake.paramsForMethod("comment.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-1"])
        let thread: [String: Any] = [
            "threadId": "t1", "noteId": "note-1", "status": "open", "createdAt": "2024-01-01T00:00:00Z",
            "lastActivity": "2024-01-01T00:00:00Z", "commentCount": 1
        ]
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", seq: 0, snapshot: [thread]))
        #expect(store.threads.isEmpty, "The torn-down subscription publishes nothing")

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-2"]
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-2")
        #expect(fake.unregisteredSubscriptionIds.isEmpty)
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
    }

    @Test func duplicateSubscribeAckReregistersTheSameHandler() async throws {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": []]
        fake.pendingMethods = ["workspace.subscribe"]

        // Two connect notifications race to subscribe; the daemon acks both with one id.
        fake.simulateConnect()
        fake.simulateConnect()
        try await fake.waitForPendingRequests("workspace.subscribe", count: 2)
        fake.pendingMethods = []
        fake.resolvePending("workspace.subscribe", with: ["subscriptionId": "sub-1"])
        fake.resolvePending("workspace.subscribe", with: ["subscriptionId": "sub-1"])
        try await waitUntil("second ack") { fake.unregisteredSubscriptionIds.count == 1 }

        #expect(fake.unregisteredSubscriptionIds == ["sub-1"])
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", seq: 0, snapshot: [
            ["id": "ws-1", "title": "Workspace"]
        ]))
        #expect(store.workspaces.map(\.id) == ["ws-1"])
    }

    @Test func noteStoreWorkspaceSwitchUnregistersPreviousSubscriptionHandler() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "note-sub-ws1"]
        await store.fetchNotes(workspaceId: "ws-1")
        fake.simulateConnect()
        try await waitUntil("ws-1 note subscription") { fake.hasSubscriptionHandler(id: "note-sub-ws1") }

        await store.fetchNotes(workspaceId: "ws-2")
        #expect(!fake.hasSubscriptionHandler(id: "note-sub-ws1"), "Switching workspaces must unregister the old handler")
    }
}
