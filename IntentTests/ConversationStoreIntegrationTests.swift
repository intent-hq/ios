import Foundation
import Testing
import Combine
@testable import Intent

@MainActor
struct ConversationStoreIntegrationTests {
    
    // MARK: - subscribeOnConnect
    
    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure all responses needed for subscribeLiveChat
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        // Call subscribeLiveChat directly (no simulateConnect needed)
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify subscribe was called
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }
    
    // MARK: - contiguousDeltaAdvancesState
    
    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.messages.count == 1)
        
        // Contiguous delta
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 1,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(
                added: [["id": "msg-2", "role": "assistant", "contentBlocks": [["type": "text", "text": "World"]], "timestamp": "2024-01-02T00:00:00Z"]],
                updated: [],
                removedIds: []
            )
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.messages.count == 2)
    }
    
    // MARK: - gapTriggersResnapshotWithBaselineRefetch
    
    @Test func gapTriggersResnapshotWithBaselineRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        
        fake.clearRequestLog()
        
        // Gap (seq 5 instead of 1) triggers resnapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 5,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        ))
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Verify resnapshot: unsubscribe, subscribe, getConversation
        #expect(fake.didCallMethod("chat.unsubscribe"))
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.didCallMethod("agent.getConversation"))
    }
    
    // MARK: - connectionLossClearsLiveThenReconnectResubscribes
    
    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure all responses needed for onReconnected flow
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        // Initial setup - simulate connected and subscribe
        fake.simulateConnect()
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.messages.count == 1)

        // Disconnect
        fake.clearRequestLog()
        fake.simulateDisconnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Reconnect (triggers onReconnected which calls everything)
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify fresh subscribe + getConversation (both called from onReconnected)
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.didCallMethod("agent.getConversation"))
    }
}
