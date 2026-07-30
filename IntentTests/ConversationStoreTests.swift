import Foundation
import Testing
@testable import Intent

/// Tests for ConversationStore – covers reset behavior and lastFailedSend tracking.
@MainActor
struct ConversationStoreTests {

    // MARK: - Helpers

    private func makeAgent(
        id: String = "agent-1",
        name: String = "Test",
        status: String = "Idle",
        isStreaming: Bool = false,
        isProcessing: Bool = false,
        isResponding: Bool = false
    ) -> AgentSession {
        AgentSession(
            id: id, name: name, status: status,
            isBackground: false, isStreaming: isStreaming,
            isProcessing: isProcessing, isResponding: isResponding,
            isWaitingForOtherAgents: false, waitingForAgentIds: [],
            createdAt: nil, updatedAt: nil, lastActivity: nil,
            lastAgentResponse: nil, lastUserMessage: nil,
            digest: nil, specialist: nil, createdByAgentId: nil,
            attentionRequestKind: nil, attentionRequestReason: nil,
            attentionRequestTimestamp: nil
        )
    }

    // MARK: - reset clears all relevant state

    @Test func resetClearsAllState() {
        let store = ConversationStore()
        store.watchedAgents.append(makeAgent(id: "watched"))
        store.watchedAgentIds.append("watched")
        store.isWaitingForAgents = true
        store.reset()
        #expect(store.watchedAgents.isEmpty)
        #expect(store.watchedAgentIds.isEmpty)
        #expect(store.isWaitingForAgents == false)
        #expect(store.messages.isEmpty)
    }

    // MARK: - lastFailedSend tracking (duplicate message prevention)

    @Test func lastFailedSendStartsNil() {
        let store = ConversationStore()
        #expect(store.lastFailedSend == nil)
    }

    @Test func retryWithSameContentReusesMessageId() {
        let store = ConversationStore()
        // Simulate a previous failed send
        store.lastFailedSend = (messageId: "failed-id-123", content: "Hello")
        // Add a stale optimistic message from the failed attempt
        let staleMessage = ConversationMessage(
            id: "failed-id-123",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "Hello")]
        )
        store.messages.append(staleMessage)
        #expect(store.messages.count == 1)

        // Simulate what sendMessage does: check lastFailedSend and reuse messageId
        let content = "Hello"
        let messageId: String
        if let failed = store.lastFailedSend, failed.content == content {
            messageId = failed.messageId
            store.messages.removeAll { $0.id == failed.messageId }
        } else {
            messageId = UUID().uuidString
        }

        #expect(messageId == "failed-id-123", "Should reuse the failed messageId")
        #expect(store.messages.isEmpty, "Stale optimistic message should be removed")
    }

    @Test func retryWithDifferentContentGeneratesNewId() {
        let store = ConversationStore()
        store.lastFailedSend = (messageId: "failed-id-123", content: "Hello")

        let content = "Goodbye"
        let messageId: String
        if let failed = store.lastFailedSend, failed.content == content {
            messageId = failed.messageId
        } else {
            messageId = UUID().uuidString
        }

        #expect(messageId != "failed-id-123", "Should generate a new messageId for different content")
    }

    @Test func resetClearsLastFailedSend() {
        let store = ConversationStore()
        store.lastFailedSend = (messageId: "failed-id-123", content: "Hello")
        #expect(store.lastFailedSend != nil)
        store.reset()
        #expect(store.lastFailedSend == nil, "reset() should clear lastFailedSend")
    }

    @Test func staleOptimisticMessageCleanedUpOnRetry() {
        let store = ConversationStore()
        // Simulate failed send left an optimistic message
        store.lastFailedSend = (messageId: "msg-abc", content: "Test message")
        let staleMsg = ConversationMessage(
            id: "msg-abc",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "Test message")]
        )
        let otherMsg = ConversationMessage(
            id: "other-msg",
            role: .assistant,
            contentBlocks: [ContentBlock(type: .text, text: "Response")]
        )
        store.messages = [staleMsg, otherMsg]
        #expect(store.messages.count == 2)

        // Simulate retry logic from sendMessage
        let content = "Test message"
        if let failed = store.lastFailedSend, failed.content == content {
            store.messages.removeAll { $0.id == failed.messageId }
        }

        #expect(store.messages.count == 1, "Only the stale optimistic message should be removed")
        #expect(store.messages[0].id == "other-msg", "Other messages should be preserved")
    }

    // MARK: - rollbackFailedSend (failed send must not supersede pending questions)

    @Test func rollbackFailedSendRemovesOptimisticMessageAndThinking() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32000)
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(agentId: "a", content: "Q: x\nA: y", workspaceId: "w")
        }
        #expect(store.messages.count == 1, "failed send leaves the optimistic message")
        #expect(store.isStreaming, "failed send leaves the optimistic thinking state")

        store.rollbackFailedSend()

        #expect(store.messages.isEmpty, "rollback removes the optimistic message")
        #expect(store.isStreaming == false, "rollback resets the thinking state")
        #expect(store.lastFailedSend != nil, "retry dedup tracking is preserved")
    }

    @Test func rollbackFailedSendIsNoopWithoutTrackedFailure() {
        let store = ConversationStore()
        store.messages = [
            ConversationMessage(
                id: "m1", role: .user,
                contentBlocks: [ContentBlock(type: .text, text: "hi")]
            ),
        ]
        store.isStreaming = true

        store.rollbackFailedSend()

        #expect(store.messages.count == 1)
        #expect(store.isStreaming)
    }

    // MARK: - attention request raise/retire (PROTOCOL §5.5)

    @Test func fetchAgentStreamingStateRaisesAttentionRequest() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "A",
                "attentionRequestKind": "blocker",
                "attentionRequestReason": "sandbox is broken"
            ] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.attentionRequest?.kind == .blocker)
        #expect(store.attentionRequest?.reason == "sandbox is broken")
    }

    @Test func fetchAgentStreamingStateClearsWhenServerHasNone() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": ["id": "a", "name": "A"] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.attentionRequest = PendingAttentionRequest(kind: .discussion, reason: "stale")

        // Attention state is server-authoritative even with raiseOnly (which
        // only guards isStreaming).
        await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true)

        #expect(store.attentionRequest == nil)
    }

    @Test func fetchAgentStreamingStateUpdatesAttentionOnPartialPayload() async {
        // Attention state must raise/clear even when the payload lacks the
        // name required by the full session parse.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a",
                "attentionRequestKind": "blocker"
            ] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.attentionRequest?.kind == .blocker)
    }

    @Test func sendMessageRetiresAttentionRequest() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.attentionRequest = PendingAttentionRequest(kind: .blocker, reason: "why")

        try await store.sendMessage(agentId: "a", content: "unblocking you", workspaceId: "w")

        #expect(store.attentionRequest == nil, "sending a message retires the indicator immediately")
    }

    @Test func failedSendKeepsAttentionRequest() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32000)
        let store = ConversationStore(connectionManager: fake)
        store.attentionRequest = PendingAttentionRequest(kind: .discussion, reason: "input needed")

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(agentId: "a", content: "hi", workspaceId: "w")
        }

        #expect(store.attentionRequest != nil, "a failed send must not retire the indicator")
    }

    @Test func resetClearsAttentionRequest() {
        let store = ConversationStore()
        store.attentionRequest = PendingAttentionRequest(kind: .blocker, reason: "why")
        store.reset()
        #expect(store.attentionRequest == nil)
    }
}

