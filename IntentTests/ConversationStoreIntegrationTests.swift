import Foundation
import Testing
import Combine
@testable import Intent

/// Store-level integration tests for ConversationStore chat.subscribe lifecycle.
@MainActor
struct ConversationStoreIntegrationTests {
    
    @Test func subscribesOnAgentLoad() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.requestResponses["chat.subscribe"] = ["subscriptionId": "sub-chat-123"]
        fake.requestResponses["conversation.list"] = ["messages": []]
        fake.requestResponses["conversation.queue"] = ["queuedMessages": []]
        fake.requestResponses["agent.get"] = ["agent": ["id": "agent-1", "status": "idle", "isStreaming": false]]
        fake.requestResponses["agent.subscriptions.list"] = ["subscriptions": []]

        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-test")
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(fake.didRequest(method: "chat.subscribe"))
    }
    
    @Test func appliesContiguousDelta() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.requestResponses["chat.subscribe"] = ["subscriptionId": "sub-chat-123"]
        fake.requestResponses["conversation.list"] = ["messages": []]
        fake.requestResponses["conversation.queue"] = ["queuedMessages": []]
        fake.requestResponses["agent.get"] = ["agent": ["id": "agent-1", "status": "idle", "isStreaming": false]]
        fake.requestResponses["agent.subscriptions.list"] = ["subscriptions": []]

        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-test")
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 200_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-chat-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "content": [["type": "text", "text": "Hello"]],
                    "timestamp": "2026-07-17T12:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-chat-123",
            kind: .delta,
            seq: 1,
            delta: SubscriptionPush.DeltaPayload(
                added: [[
                    "id": "msg-2",
                    "role": "assistant",
                    "content": [["type": "text", "text": "Hi"]],
                    "timestamp": "2026-07-17T12:01:00Z"
                ]],
                updated: [],
                removedIds: []
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.messages.count == 2)
    }
    
    @Test func gapTriggersResnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.requestResponses["chat.subscribe"] = ["subscriptionId": "sub-chat-123"]
        fake.requestResponses["conversation.list"] = ["messages": []]
        fake.requestResponses["conversation.queue"] = ["queuedMessages": []]
        fake.requestResponses["agent.get"] = ["agent": ["id": "agent-1", "status": "idle", "isStreaming": false]]
        fake.requestResponses["agent.subscriptions.list"] = ["subscriptions": []]

        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-test")
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 200_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-chat-123",
            kind: .snapshot,
            seq: 0,
            snapshot: []
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        fake.requestLog.removeAll()
        
        // Gap
        fake.injectSubscriptionPush(
            subscriptionId: "sub-chat-123",
            kind: .delta,
            seq: 5,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        
        #expect(fake.didRequest(method: "chat.unsubscribe"))
        #expect(fake.requestLog.filter { $0.method == "chat.subscribe" }.count >= 1)
    }
    
    @Test func wrongSubscriptionIdDropped() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.requestResponses["chat.subscribe"] = ["subscriptionId": "sub-chat-correct"]
        fake.requestResponses["conversation.list"] = ["messages": []]
        fake.requestResponses["conversation.queue"] = ["queuedMessages": []]
        fake.requestResponses["agent.get"] = ["agent": ["id": "agent-1", "status": "idle", "isStreaming": false]]
        fake.requestResponses["agent.subscriptions.list"] = ["subscriptions": []]

        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-test")
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 200_000_000)
        
        fake.injectSubscriptionPush(
            subscriptionId: "sub-chat-correct",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "content": [["type": "text", "text": "Correct"]],
                    "timestamp": "2026-07-17T12:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.messages.count == 1)
        
        // Wrong subscriptionId
        fake.injectSubscriptionPush(
            subscriptionId: "sub-chat-WRONG",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "msg-2",
                    "role": "user",
                    "content": [["type": "text", "text": "Wrong"]],
                    "timestamp": "2026-07-17T12:01:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.messages.count == 1)
    }
}
