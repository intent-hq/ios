import Foundation
@testable import Intent
import Testing

/// Integration tests for CommentStore using FakeConnectionManager to verify end-to-end subscription behavior
@MainActor
struct CommentStoreIntegrationTests {
    /// Connects the fake and subscribes `store` to note-1, then waits for the
    /// connect observer's own resubscribe (it runs from a detached task and
    /// resets live state) so it cannot interleave with the test body.
    private func connectAndSubscribe(_ fake: FakeConnectionManager, _ store: CommentStore) async throws {
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await fake.waitForRequests("comment.subscribe", count: 2)
    }

    // MARK: - subscribeOnConnect

    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - contiguousDeltaAdvancesState

    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        // Snapshot baseline (pushes are applied synchronously)
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

        // Contiguous delta (seq 0 → 1)
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

    // MARK: - gapTriggersResnapshot

    @Test func gapTriggersResnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        // Snapshot baseline
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

        // Gap delta (seq 0 → 10)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-A",
            seq: 10,
            delta: SubscriptionPush.DeltaPayload(
                added: [],
                updated: [],
                removedIds: []
            )
        ))
        // Registering sub-B is the last step of resnapshot, so it proves the
        // unsubscribe and subscribe already ran.
        try await waitUntil("resnapshot to register sub-B") {
            fake.hasSubscriptionHandler(id: "sub-B")
        }

        // Verify unsubscribe + subscribe
        #expect(fake.didCallMethod("comment.unsubscribe"))
        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-A"))
    }

    // MARK: - connectionLossClearsLiveThenReconnectResubscribes

    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        // Snapshot baseline
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

        // Disconnect, then reconnect with a fresh subscription id so the
        // resubscribe is distinguishable from the original registration.
        fake.clearRequestLog()
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-2", "seq": 0, "snapshot": []]
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("reconnect resubscribe") {
            fake.hasSubscriptionHandler(id: "sub-2")
        }

        // Verify fresh subscribe
        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - crossIdPushIsolation

    @Test func crossIdPushIsolation() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        try await connectAndSubscribe(fake, store)

        // Snapshot for sub-A
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

        // Push for unregistered sub-B (should be ignored by store)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-B",
            seq: 0,
            snapshot: [
                ["threadId": "t99", "noteId": "note-99", "anchor": ["anchorText": "should not appear"], "comments": []]
            ],
        ))

        // Verify state unchanged
        #expect(store.threads.count == 1)
        #expect(store.threads[0].id == "t1")
        #expect(!fake.hasSubscriptionHandler(id: "sub-B"))
    }

    // MARK: - deinit removes event + subscription handlers (monorepo#2211, monorepo#2213)

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
        // deinit hops to the main actor to remove the handlers; wait for that task
        try await waitUntil("deinit to remove event + subscription handlers") {
            fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }
}
