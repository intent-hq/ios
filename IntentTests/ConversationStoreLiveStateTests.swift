import Foundation
import Testing
@testable import Intent

@MainActor
struct ConversationStoreLiveStateTests {
    
    // MARK: - Snapshot application
    
    @Test func appliesSnapshot() async throws {
        let store = ConversationStore()
        
        // Initialize reconciler for test
        await store.setTestReconciler(DeltaReconciler<ConversationMessage>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in ConversationMessage.parseMessage(dict) }
        ))
        
        // Simulate subscription.push snapshot
        let params: [String: Any] = [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "text": "Hello"]]
                ],
                [
                    "id": "msg-2",
                    "role": "assistant",
                    "contentBlocks": [["type": "text", "text": "Hi there"]]
                ]
            ]
        ]
        
        store.handleStreamEvent("subscription.push", params: params)
        
        let messages = store.messages
        #expect(messages.count == 2)
        #expect(messages[0].id == "msg-1")
        #expect(messages[1].id == "msg-2")
    }
    
    // MARK: - Contiguous delta application
    
    @Test func appliesContiguousDelta() async throws {
        let store = ConversationStore()
        
        // Initialize reconciler for test
        await store.setTestReconciler(DeltaReconciler<ConversationMessage>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in ConversationMessage.parseMessage(dict) }
        ))
        
        // First, apply snapshot
        let snapshotParams: [String: Any] = [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "text": "Hello"]]
                ]
            ]
        ]
        store.handleStreamEvent("subscription.push", params: snapshotParams)
        
        // Then apply delta
        let deltaParams: [String: Any] = [
            "subscriptionId": "sub-chat-123",
            "kind": "delta",
            "seq": 1,
            "delta": [
                "added": [
                    [
                        "id": "msg-2",
                        "role": "assistant",
                        "contentBlocks": [["type": "text", "text": "Hi"]]
                    ]
                ],
                "updated": [],
                "removedIds": []
            ]
        ]
        store.handleStreamEvent("subscription.push", params: deltaParams)
        
        let messages = store.messages
        #expect(messages.count == 2)
        #expect(messages[0].id == "msg-1")
        #expect(messages[1].id == "msg-2")
    }
    
    // MARK: - Gap detection
    
    @Test func detectsGapAndReturnsFalse() async throws {
        let store = ConversationStore()
        
        // Initialize reconciler for test
        await store.setTestReconciler(DeltaReconciler<ConversationMessage>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in ConversationMessage.parseMessage(dict) }
        ))
        
        // Apply snapshot
        let snapshotParams: [String: Any] = [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "text": "Hello"]]
                ]
            ]
        ]
        store.handleStreamEvent("subscription.push", params: snapshotParams)
        
        // Try to apply delta with wrong seq (gap)
        let deltaParams: [String: Any] = [
            "subscriptionId": "sub-chat-123",
            "kind": "delta",
            "seq": 5, // Expected 1, got 5 — gap
            "delta": [
                "added": [
                    [
                        "id": "msg-2",
                        "role": "assistant",
                        "contentBlocks": [["type": "text", "text": "Hi"]]
                    ]
                ],
                "updated": [],
                "removedIds": []
            ]
        ]
        store.handleStreamEvent("subscription.push", params: deltaParams)
        
        // Should still have only 1 message (delta rejected due to gap)
        let messages = store.messages
        #expect(messages.count == 1)
    }
    
    // MARK: - Malformed push rejection
    
    @Test func rejectsMalformedPush() async throws {
        // Snapshot push missing "snapshot" field
        let malformedParams: [String: Any] = [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0
            // Missing "snapshot" field
        ]
        
        let push = SubscriptionPush.parse(method: "subscription.push", params: malformedParams)
        #expect(push == nil) // Should return nil for malformed push
    }
}
