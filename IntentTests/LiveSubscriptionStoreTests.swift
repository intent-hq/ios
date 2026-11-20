import Foundation
@testable import Intent
import Testing

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

        fake.pendingMethods = ["task.unsubscribe"]
        fake.deliverSubscriptionPush(gap("sub-1"))
        try await fake.waitForPendingRequests("task.unsubscribe")
        #expect(fake.unregisteredSubscriptionIds == ["sub-1"])

        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("reconnect subscription") { fake.hasSubscriptionHandler(id: "sub-2") }
        #expect(fake.unregisteredSubscriptionIds == ["sub-1", "sub-1"])

        fake.pendingMethods = []
        fake.resolvePending("task.unsubscribe", with: ["ok": true])
        try await expectNever("superseded resnapshot subscribing again", within: .milliseconds(150)) {
            fake.hasSubscriptionHandler(id: "sub-3")
        }
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))

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

    private func subscribedNoteStore(acks: [String]) async throws -> (NoteStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.unsubscribe"] = [:] as [String: Any]
        fake.responseQueueMap["note.subscribe"] = acks.map { ["subscriptionId": $0] }
        await store.fetchNotes(workspaceId: "ws-1")
        fake.simulateConnect()
        try await waitUntil("ws-1 note subscription") { fake.hasSubscriptionHandler(id: acks[0]) }
        return (store, fake)
    }

    private func noteSubscribeWorkspaces(_ fake: FakeConnectionManager) -> [String] {
        fake.paramsForMethod("note.subscribe").compactMap { $0["workspaceId"] as? String }
    }

    @Test func noteStoreWorkspaceSwitchUnregistersPreviousSubscriptionHandler() async throws {
        let (store, fake) = try await subscribedNoteStore(acks: ["note-sub-ws1", "note-sub-ws2"])

        await store.fetchNotes(workspaceId: "ws-2")
        #expect(!fake.hasSubscriptionHandler(id: "note-sub-ws1"), "Switching workspaces must unregister the old handler")
        try await waitUntil("old subscription released daemon-side") {
            fake.paramsForMethod("note.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["note-sub-ws1"]
        }
    }

    @Test func noteStoreWorkspaceSwitchSubscribesTheNewWorkspace() async throws {
        let (store, fake) = try await subscribedNoteStore(acks: ["note-sub-ws1", "note-sub-ws2"])

        await store.fetchNotes(workspaceId: "ws-2")
        #expect(fake.hasSubscriptionHandler(id: "note-sub-ws2"))
        #expect(store.liveSubscription == .subscribed(id: "note-sub-ws2"))
        #expect(noteSubscribeWorkspaces(fake) == ["ws-1", "ws-2"])
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "note-sub-ws2", seq: 0, snapshot: [
            ["id": "n-2", "title": "Live in ws-2", "content": "", "createdAt": "", "updatedAt": ""]
        ]))
        #expect(store.notes.map(\.title) == ["Live in ws-2"])

        await store.fetchNotes(workspaceId: "ws-2")
        #expect(noteSubscribeWorkspaces(fake) == ["ws-1", "ws-2"])
    }

    @Test func noteStoreLateAckFromPreviousWorkspaceIsReleased() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.unsubscribe"] = [:] as [String: Any]
        fake.pendingMethods = ["note.subscribe"]
        await store.fetchNotes(workspaceId: "ws-1")
        fake.simulateConnect()
        try await fake.waitForPendingRequests("note.subscribe")

        let switching = Task { await store.fetchNotes(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("note.subscribe", count: 2)
        fake.pendingMethods = []
        fake.resolvePending("note.subscribe", with: ["subscriptionId": "late-ws1"])
        fake.resolvePending("note.subscribe", with: ["subscriptionId": "sub-ws2"])
        await switching.value
        try await waitUntil("late ack released") {
            fake.paramsForMethod("note.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["late-ws1"]
        }

        #expect(!fake.hasSubscriptionHandler(id: "late-ws1"))
        #expect(fake.hasSubscriptionHandler(id: "sub-ws2"))
        #expect(store.liveSubscription == .subscribed(id: "sub-ws2"))
        #expect(noteSubscribeWorkspaces(fake) == ["ws-1", "ws-2"])
    }

    @Test func noteStoreRapidWorkspaceSwitchesSubscribeOnlyTheLastWorkspace() async throws {
        let (store, fake) = try await subscribedNoteStore(acks: ["sub-ws1", "sub-ws1-again", "unexpected"])
        fake.pendingMethods = ["note.list"]

        let toWs2 = Task { await store.fetchNotes(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("note.list")
        let backToWs1 = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list", count: 2)
        fake.pendingMethods = []
        fake.resolvePending("note.list", with: ["notes": []])
        fake.resolvePending("note.list", with: ["notes": []])
        await toWs2.value
        await backToWs1.value

        #expect(noteSubscribeWorkspaces(fake) == ["ws-1", "ws-1"])
        #expect(store.liveSubscription == .subscribed(id: "sub-ws1-again"))
        #expect(fake.hasSubscriptionHandler(id: "sub-ws1-again"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-ws1"))
        try await expectNever("a subscription for the skipped workspace", within: .milliseconds(100)) {
            fake.paramsForMethod("note.subscribe").count > 2
        }
    }

    @Test func noteStoreFirstWorkspaceAfterIdleConnectSubscribesOnce() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseQueueMap["note.subscribe"] = [["subscriptionId": "sub-1"], ["subscriptionId": "unexpected"]]
        fake.simulateConnect()
        let store = NoteStore(connectionManager: fake)
        try await waitUntil("idle onConnected") { store.liveSubscriptionGeneration == 1 }
        #expect(!fake.didCallMethod("note.subscribe"))

        await store.fetchNotes(workspaceId: "ws-1")
        #expect(noteSubscribeWorkspaces(fake) == ["ws-1"])
        #expect(store.liveSubscription == .subscribed(id: "sub-1"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
        try await expectNever("a second subscribe", within: .milliseconds(100)) {
            fake.paramsForMethod("note.subscribe").count > 1
        }
    }

    @Test func noteStoreFirstFetchWithQueuedConnectSubscribesOnce() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseQueueMap["note.subscribe"] = ["sub-1", "sub-2"].map { ["subscriptionId": $0] }
        fake.simulateConnect()
        let store = NoteStore(connectionManager: fake)
        await store.fetchNotes(workspaceId: "ws-1")
        try await waitUntil("ws-1 subscribed") { store.liveSubscription.id != nil }
        try await expectNever("a second subscribe or handler", within: .milliseconds(150)) {
            fake.paramsForMethod("note.subscribe").count > 1 || fake.subscriptionHandlerCount > 1
        }
        #expect(noteSubscribeWorkspaces(fake) == ["ws-1"])
        #expect(store.liveSubscription == .subscribed(id: "sub-1"))
        #expect(fake.subscriptionHandlerCount == 1)
        #expect(fake.unregisteredSubscriptionIds.isEmpty)

        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("resubscribed after reconnect") { fake.hasSubscriptionHandler(id: "sub-2") }
        #expect(fake.unregisteredSubscriptionIds == ["sub-1"])
        #expect(fake.subscriptionHandlerCount == 1)
    }

    @Test func noteStoreSupersededSwitchToTheSameWorkspaceDoesNotSubscribe() async throws {
        let (store, fake) = try await subscribedNoteStore(acks: ["sub-ws1", "sub-ws2", "unexpected"])
        fake.responseMap["note.unsubscribe"] = [:] as [String: Any]
        fake.pendingMethods = ["note.list"]

        let first = Task { await store.fetchNotes(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("note.list")
        let second = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list", count: 2)
        let third = Task { await store.fetchNotes(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("note.list", count: 3)
        fake.pendingMethods = []

        fake.resolvePending("note.list", with: ["notes": []])
        await first.value
        #expect(store.liveSubscription == .idle)
        #expect(noteSubscribeWorkspaces(fake) == ["ws-1"])

        fake.resolvePending("note.list", with: ["notes": []])
        fake.resolvePending("note.list", with: ["notes": []])
        await second.value
        await third.value
        #expect(noteSubscribeWorkspaces(fake) == ["ws-1", "ws-2"])
        #expect(store.liveSubscription == .subscribed(id: "sub-ws2"))
        #expect(fake.subscriptionHandlerCount == 1)
    }
}
