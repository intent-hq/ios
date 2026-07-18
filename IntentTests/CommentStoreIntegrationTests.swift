import Testing
import Foundation
@testable import Intent

/// Integration tests for CommentStore using FakeConnectionManager to verify end-to-end subscription behavior
@Suite("CommentStore Integration Tests")
@MainActor
class CommentStoreIntegrationTests {
    
    // MARK: - subscribeOnConnect
    
    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #expect(fake.didCallMethod("comment.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }
    
    // MARK: - contiguousDeltaAdvancesState
    
    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Snapshot baseline
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["threadId": "t1", "noteId": "note-1", "anchor": ["anchorText": "hello"], "comments": []]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        
        // Contiguous delta (seq 0 → 1)
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .delta, seq: 1, snapshot: nil, delta: [
            "prev": 0,
            "ops": [["op": "upsert", "item": ["threadId": "t2", "noteId": "note-1", "anchor": ["anchorText": "world"], "comments": []]]]
        ]))
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.threads.count == 2)
    }
    
    // MARK: - gapTriggersResnapshotWithBaselineRefetch
    
    @Test func gapTriggersResnapshotWithBaselineRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Snapshot baseline
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-A", kind: .snapshot, seq: 0, snapshot: [
            ["threadId": "t1", "noteId": "note-1", "anchor": ["anchorText": "hello"], "comments": []]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        
        fake.clearRequestLog()
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-B", "seq": 5, "snapshot": []]
        
        // Gap delta (seq 0 → 10)
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-A", kind: .delta, seq: 10, snapshot: nil, delta: [
            "prev": 0,
            "ops": []
        ]))
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
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Snapshot baseline
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["threadId": "t1", "noteId": "note-1", "anchor": ["anchorText": "hello"], "comments": []]
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
    
    // MARK: - crossIdPushIsolation
    
    @Test func crossIdPushIsolation() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Snapshot for sub-A
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-A", kind: .snapshot, seq: 0, snapshot: [
            ["threadId": "t1", "noteId": "note-1", "anchor": ["anchorText": "hello"], "comments": []]
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

    // MARK: - noteSwitchClearsPreviousSubscription

    @Test func noteSwitchClearsPreviousSubscription() async throws {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)

        // Subscribe to note-1
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-note1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        try await Task.sleep(nanoseconds: 100_000_000)

        // Snapshot for note-1
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-note1", kind: .snapshot, seq: 0, snapshot: [
            ["threadId": "t1", "noteId": "note-1", "anchor": ["anchorText": "hello"], "comments": []]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.threads.count == 1)
        #expect(fake.hasSubscriptionHandler(id: "sub-note1"))

        fake.clearRequestLog()
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-note2", "seq": 0, "snapshot": []]

        // Switch to note-2
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-2")
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify old subscription unregistered and new subscription active
        #expect(fake.didCallMethod("comment.unsubscribe"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-note1"))
        #expect(fake.hasSubscriptionHandler(id: "sub-note2"))

        // Snapshot for note-2
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-note2", kind: .snapshot, seq: 0, snapshot: [
            ["threadId": "t2", "noteId": "note-2", "anchor": ["anchorText": "world"], "comments": []]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify state switched to note-2
        #expect(store.threads.count == 1)
        #expect(store.threads[0].id == "t2")

        // Deliver late push for note-1 (should be ignored)
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-note1", kind: .delta, seq: 1, snapshot: nil, delta: [
            "prev": 0,
            "ops": [["op": "upsert", "item": ["threadId": "t99", "noteId": "note-1", "anchor": ["anchorText": "late"], "comments": []]]]
        ]))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify state unchanged (late push ignored)
        #expect(store.threads.count == 1)
        #expect(store.threads[0].id == "t2")
    }
}
