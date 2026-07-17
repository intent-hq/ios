import Foundation
import Testing
import Combine
@testable import Intent

/// Store-level integration tests for CommentStore subscribe lifecycle.
@MainActor
struct CommentStoreIntegrationTests {
    
    @Test func subscribesOnNoteSubscription() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.requestResponses["comment.subscribe"] = ["subscriptionId": "sub-comments-123"]
        
        await store.subscribeToNote(workspaceId: "ws-test", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #expect(fake.didRequest(method: "comment.subscribe"))
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-comments-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["threadId": "thread-1", "noteId": "note-1", "comments": []]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.threads.count == 1)
    }
    
    @Test func appliesContiguousDelta() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.requestResponses["comment.subscribe"] = ["subscriptionId": "sub-comments-123"]
        await store.subscribeToNote(workspaceId: "ws-test", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-comments-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["threadId": "thread-1", "noteId": "note-1", "comments": []]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-comments-123",
            kind: .delta,
            seq: 1,
            delta: SubscriptionPush.DeltaPayload(
                added: [["threadId": "thread-2", "noteId": "note-1", "comments": []]],
                updated: [],
                removedIds: []
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.threads.count == 2)
    }
    
    @Test func gapTriggersResnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.requestResponses["comment.subscribe"] = ["subscriptionId": "sub-comments-123"]
        await store.subscribeToNote(workspaceId: "ws-test", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-comments-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["threadId": "thread-1", "noteId": "note-1", "comments": []]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        fake.requestLog.removeAll()
        
        // Gap
        fake.injectSubscriptionPush(
            subscriptionId: "sub-comments-123",
            kind: .delta,
            seq: 5,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        
        #expect(fake.didRequest(method: "comment.unsubscribe"))
        #expect(fake.requestLog.filter { $0.method == "comment.subscribe" }.count >= 1)
    }
    
    @Test func wrongSubscriptionIdDropped() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.requestResponses["comment.subscribe"] = ["subscriptionId": "sub-comments-correct"]
        await store.subscribeToNote(workspaceId: "ws-test", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-comments-correct",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["threadId": "thread-1", "noteId": "note-1", "comments": []]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        
        // Wrong subscriptionId
        fake.injectSubscriptionPush(
            subscriptionId: "sub-comments-WRONG",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["threadId": "thread-2", "noteId": "note-1", "comments": []]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.threads.count == 1)
    }
    
    @Test func connectionLossAndReconnect() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.requestResponses["comment.subscribe"] = ["subscriptionId": "sub-comments-123"]
        await store.subscribeToNote(workspaceId: "ws-test", noteId: "note-1")
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        fake.requestLog.removeAll()
        fake.simulateDisconnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #expect(fake.didRequest(method: "comment.subscribe"))
    }
}
