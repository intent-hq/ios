import Foundation
@testable import Intent
import Testing

/// Tests for ConversationStore – covers reset behavior and lastFailedSend tracking.
@MainActor
struct ConversationStoreTests {
    // MARK: - Helpers

    func makeAgent(
        id: String = "agent-1",
        name: String = "Test",
        status: String = "Idle",
        isStreaming: Bool = false,
        isProcessing: Bool = false,
        isResponding: Bool = false
    ) -> AgentSession {
        AgentSession(
            id: id,
            name: name,
            status: status,
            isBackground: false,
            isStreaming: isStreaming,
            isProcessing: isProcessing,
            isResponding: isResponding,
            isWaitingForOtherAgents: false,
            waitingForAgentIds: [],
            createdAt: nil,
            updatedAt: nil,
            lastActivity: nil,
            lastAgentResponse: nil,
            lastUserMessage: nil,
            lastMessageRole: nil,
            digest: nil,
            specialist: nil,
            createdByAgentId: nil,
            attentionRequestKind: nil,
            attentionRequestReason: nil,
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
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32_000)
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
                id: "m1",
                role: .user,
                contentBlocks: [ContentBlock(type: .text, text: "hi")]
            )
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
                "id": "a",
                "name": "A",
                "attentionRequestKind": "blocker",
                "attentionRequestReason": "sandbox is broken",
                "attentionRequestTimestamp": "2026-07-30T10:00:00Z"
            ] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.attentionRequest?.kind == .blocker)
        #expect(store.attentionRequest?.reason == "sandbox is broken")
        #expect(store.attentionRequest?.raisedAt == ISO8601DateFormatter().date(from: "2026-07-30T10:00:00Z"))
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

    // MARK: - sendMessage messageMetadata threading (intent-hq/monorepo#1789)
}

extension ConversationStoreTests {
    @Test func sendMessageThreadsMessageMetadataToWire() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(
            agentId: "a",
            content: "Q: x\nA: y",
            workspaceId: "w",
            messageMetadata: .fields([
                "type": "question_answers",
                "answeredQuestionsMessageId": "msg-q1"
            ])
        )

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let metadata = try #require(sent.params["messageMetadata"] as? [String: Any])
        #expect(metadata["type"] as? String == "question_answers")
        #expect(metadata["answeredQuestionsMessageId"] as? String == "msg-q1")
    }

    @Test func sendMessageOmitsMessageMetadataWhenAbsent() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(agentId: "a", content: "hi", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["messageMetadata"] == nil, "plain sends stay untagged")
    }

    @Test func failedSendKeepsAttentionRequest() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32_000)
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

    // MARK: - agentNotFound (missing-agent fallback)

    @Test func fetchConversationNotFoundRaisesAgentNotFound() async {
        let fake = FakeConnectionManager()
        // agent.getConversation answers -32602 with data.code == "not-found" for a
        // nonexistent agent (docs/PROTOCOL.md §3.3/§9)
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: gone",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "gone", workspaceId: "w")

        #expect(store.agentNotFound, "a definitive not-found must raise agentNotFound")
    }

    @Test func fetchConversationBare32602DoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "a -32602 without data.code == \"not-found\" must not raise agentNotFound")
    }

    @Test func fetchConversationInvalidParams32602DoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "Missing required parameter: agentId",
                NSError.intentErrorDataCodeKey: "invalid-params"
            ]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "data.code == \"invalid-params\" must not raise agentNotFound")
    }

    @Test func fetchConversationTransientErrorDoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "a transient transport error must not raise agentNotFound")
    }

    @Test func fetchAgentStreamingStateNotFoundRaisesAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: gone",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "gone")

        #expect(store.agentNotFound)
    }

    @Test func agentDeletedEventForOpenAgentRaisesAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        #expect(!store.agentNotFound)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:deleted", "data": ["agentId": "a"]] as [String: Any]
        ])

        #expect(store.agentNotFound, "agent:deleted for the open agent must raise agentNotFound")
    }

    @Test func agentDeletedEventForOtherAgentDoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:deleted", "data": ["agentId": "someone-else"]] as [String: Any]
        ])

        #expect(!store.agentNotFound, "agent:deleted for a different agent must not raise agentNotFound")
    }

    @Test func resetClearsAgentNotFound() {
        let store = ConversationStore()
        store.agentNotFound = true
        store.reset()
        #expect(!store.agentNotFound)
    }

    // MARK: - dismissQuestions (agent.dismissQuestions, PROTOCOL §5.5)

    @Test func dismissQuestionsCallsRpcAndRaisesMarker() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.dismissQuestions"] = [
            "success": true,
            "dismissedQuestionsMessageId": "a1"
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.dismissQuestions(agentId: "a", messageId: "a1", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.dismissQuestions" })
        #expect(sent.params["agentId"] as? String == "a")
        #expect(sent.params["messageId"] as? String == "a1")
        #expect(sent.params["workspaceId"] as? String == "w")
        #expect(store.dismissedQuestionsMessageId == "a1")
    }
}
