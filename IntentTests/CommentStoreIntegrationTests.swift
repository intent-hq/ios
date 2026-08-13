import Testing
import Foundation
@testable import Intent

/// Integration tests for CommentStore using FakeConnectionManager to verify end-to-end subscription behavior
@MainActor
struct CommentStoreIntegrationTests {
    
    // MARK: - subscribeOnConnect
    
    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }
    
    // MARK: - contiguousDeltaAdvancesState
    
    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot baseline
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
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
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        
        // Contiguous delta (seq 0 → 1)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 1,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(
                added: [[
                    "threadId": "t2",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2024-01-02T00:00:00Z",
                    "lastActivity": "2024-01-02T00:00:00Z",
                    "latestCommentAuthor": "user2",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2024-01-02T00:00:00Z",
                    "commentCount": 1
                ]],
                updated: [],
                removedIds: []
            )
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.threads.count == 2)
    }
    
    // MARK: - gapTriggersResnapshot

    @Test func gapTriggersResnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot baseline
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-A", kind: .snapshot, seq: 0, snapshot: [
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
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        
        fake.clearRequestLog()
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-B", "seq": 5, "snapshot": []]

        // Gap delta (seq 0 → 10)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-A",
            kind: .delta,
            seq: 10,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(
                added: [],
                updated: [],
                removedIds: []
            )
        ))
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify unsubscribe + subscribe
        #expect(fake.didCallMethod("comment.unsubscribe"))
        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-B"))
    }
    
    // MARK: - connectionLossClearsLiveThenReconnectResubscribes
    
    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot baseline
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
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
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        
        fake.clearRequestLog()
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-2", "seq": 0, "snapshot": []]
        fake.simulateDisconnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Reconnect
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify fresh subscribe
        #expect(fake.didCallMethod("comment.subscribe"))
    }
    
    // MARK: - legacyEventSuppressedWhileLive

    @Test func legacyEventSuppressedWhileLive() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Snapshot establishes live state
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
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
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)

        fake.clearRequestLog()

        // Verify event handler is registered
        #expect(fake.eventHandlerCount > 0)

        // Deliver legacy event (should be suppressed)
        fake.deliverEvent(method: "comment.created", params: [
            "event": [
                "type": "comment:created",
                "workspaceId": "ws-1",
                "noteId": "note-1",
                "threadId": "t99"
            ]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify no resubscribe (legacy event suppressed)
        #expect(!fake.didCallMethod("comment.subscribe"))
        #expect(store.threads.count == 1)
    }

    // MARK: - crossIdPushIsolation

    @Test func crossIdPushIsolation() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot for sub-A
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-A", kind: .snapshot, seq: 0, snapshot: [
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
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        
        // Push for unregistered sub-B (should be ignored by store)
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-B", kind: .snapshot, seq: 0, snapshot: [
            ["threadId": "t99", "noteId": "note-99", "anchor": ["anchorText": "should not appear"], "comments": []]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        
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
        for _ in 0..<40 {
            if fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }
}
