import Foundation
@testable import Intent
import Testing

@MainActor
struct CommentStoreIntegrationTests {
    private func connectAndSubscribe(_ fake: FakeConnectionManager, _ store: CommentStore) async throws {
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await fake.waitForRequests("comment.subscribe", count: 2)
    }

    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }

    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            snapshot: [
                [
                    "threadId": "t1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "lastActivity": "2024-01-01T00:00:00Z",
                    "latestCommentAuthor": "user1",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2024-01-01T00:00:00Z",
                    "commentCount": 1
                ]
            ],
        ))
        #expect(store.threads.count == 1)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 1,
            delta: SubscriptionPush.DeltaPayload(
                added: [
                    [
                        "threadId": "t2",
                        "noteId": "note-1",
                        "status": "open",
                        "createdAt": "2024-01-02T00:00:00Z",
                        "lastActivity": "2024-01-02T00:00:00Z",
                        "latestCommentAuthor": "user2",
                        "latestCommentAuthorType": "user",
                        "latestCommentAt": "2024-01-02T00:00:00Z",
                        "commentCount": 1
                    ]
                ],
                updated: [],
                removedIds: []
            )
        ))

        #expect(store.threads.count == 2)
    }

    @Test func gapTriggersResnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-A",
            seq: 0,
            snapshot: [
                [
                    "threadId": "t1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "lastActivity": "2024-01-01T00:00:00Z",
                    "latestCommentAuthor": "user1",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2024-01-01T00:00:00Z",
                    "commentCount": 1
                ]
            ],
        ))
        #expect(store.threads.count == 1)

        fake.clearRequestLog()
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-B", "seq": 5, "snapshot": []]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-A",
            seq: 10,
            delta: SubscriptionPush.DeltaPayload(
                added: [],
                updated: [],
                removedIds: []
            )
        ))
        try await waitUntil("resnapshot to register sub-B") {
            fake.hasSubscriptionHandler(id: "sub-B")
        }

        #expect(fake.didCallMethod("comment.unsubscribe"))
        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-A"))
    }

    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            snapshot: [
                [
                    "threadId": "t1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "lastActivity": "2024-01-01T00:00:00Z",
                    "latestCommentAuthor": "user1",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2024-01-01T00:00:00Z",
                    "commentCount": 1
                ]
            ],
        ))
        #expect(store.threads.count == 1)

        fake.clearRequestLog()
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-2", "seq": 0, "snapshot": []]
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("reconnect resubscribe") {
            fake.hasSubscriptionHandler(id: "sub-2")
        }

        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
    }

    @Test func crossIdPushIsolation() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-A",
            seq: 0,
            snapshot: [
                [
                    "threadId": "t1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "lastActivity": "2024-01-01T00:00:00Z",
                    "latestCommentAuthor": "user1",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2024-01-01T00:00:00Z",
                    "commentCount": 1
                ]
            ],
        ))
        #expect(store.threads.count == 1)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-B",
            seq: 0,
            snapshot: [
                ["threadId": "t99", "noteId": "note-99", "anchor": ["anchorText": "should not appear"], "comments": []]
            ],
        ))

        #expect(store.threads.count == 1)
        #expect(store.threads[0].id == "t1")
        #expect(!fake.hasSubscriptionHandler(id: "sub-B"))
    }

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: CommentStore? = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store?.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        #expect(fake.eventHandlerCount == 1)
        #expect(fake.subscriptionHandlerCount == 1)

        store = nil
        try await waitUntil("deinit to remove event + subscription handlers") {
            fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }
}
