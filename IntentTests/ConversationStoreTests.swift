import Foundation
@testable import Intent
import Testing

/// Tests for ConversationStore – reset behavior and retained send ownership.
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

    // MARK: - Retained attempts (ordinary sends are not idempotent)

    @Test func lastFailedSendStartsNil() {
        let store = ConversationStore()
        #expect(store.lastFailedSend == nil)
    }

    @Test func newSendWithSameContentDoesNotReplayUnconfirmedIdentity() async throws {
        let fake = FakeConnectionManager()
        fake.errorQueueMap["agent.sendMessage"] = [NSError(domain: "WebSocket", code: -32_000)]
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(agentId: "a", content: "Hello", workspaceId: "w")
        }
        let failedRequest = try #require(fake.requestLog.first)
        let failedMessageId = try #require(failedRequest.params["messageId"] as? String)
        #expect(store.lastFailedSend?.id == failedMessageId)

        try await store.sendMessage(agentId: "a", content: "Hello", workspaceId: "w")

        let retryRequest = try #require(fake.requestLog.last)
        #expect(retryRequest.params["messageId"] as? String != failedMessageId)
        #expect(fake.requestLog.count == 2, "these are two explicitly requested operations, not a replay")
        #expect(store.lastFailedSend?.id == failedMessageId, "another send cannot discard unresolved recovery")
    }

    @Test func retryWithDifferentContentGeneratesNewId() async throws {
        let fake = FakeConnectionManager()
        fake.errorQueueMap["agent.sendMessage"] = [NSError(domain: "WebSocket", code: -32_000)]
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(agentId: "a", content: "Hello", workspaceId: "w")
        }
        let failedRequest = try #require(fake.requestLog.first)
        let failedMessageId = try #require(failedRequest.params["messageId"] as? String)
        let otherMessage = ConversationMessage(
            id: "other-msg",
            role: .assistant,
            contentBlocks: [ContentBlock(type: .text, text: "Response")]
        )
        store.messages.append(otherMessage)

        try await store.sendMessage(agentId: "a", content: "Goodbye", workspaceId: "w")

        let retryRequest = try #require(fake.requestLog.last)
        let retryMessageId = try #require(retryRequest.params["messageId"] as? String)
        #expect(retryMessageId != failedMessageId, "different content must not reuse the failed send's identity")
        #expect(
            store.messages.map(\.id) == [failedMessageId, otherMessage.id, retryMessageId],
            "a different send preserves the failed row and unrelated transcript rows"
        )
        #expect(store.lastFailedSend?.id == failedMessageId, "the different send preserves failure tracking")
    }

    @Test func resetClearsLastFailedSend() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2)
        let store = ConversationStore(connectionManager: fake)
        try? await store.sendMessage(agentId: "a", content: "Hello", workspaceId: "w")
        #expect(store.lastFailedSend != nil)
        store.reset()
        #expect(store.lastFailedSend == nil, "reset() should clear lastFailedSend")
    }

    @Test func knownNotSentRetryReusesOriginalPayloadAndReplacesOnlyItsRow() async throws {
        let fake = FakeConnectionManager()
        fake.errorQueueMap["agent.sendMessage"] = [DiagnosticErrorOwnership.attaching(
            to: NSError(domain: "WebSocket", code: -4),
            failure: DiagnosticFailure(origin: .localRequest, classification: .notConnected)
        )]
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(
                agentId: "a",
                content: "Test message",
                workspaceId: "w",
                imagePayload: .attachments([["type": "image", "attachmentId": "image-1"]]),
                filePayload: .attachments([["type": "file", "attachmentId": "file-1"]]),
                messageMetadata: .fields(["selection": "original"])
            )
        }
        let failedRequest = try #require(fake.requestLog.first)
        let failedMessageId = try #require(failedRequest.params["messageId"] as? String)
        #expect(store.messages.map(\.id) == [failedMessageId], "the failed send leaves its optimistic row")
        #expect(store.lastFailedSend?.status == .notSent)
        #expect(store.lastFailedSend?.canRetry == true)
        let otherMessage = ConversationMessage(
            id: "other-msg",
            role: .assistant,
            contentBlocks: [ContentBlock(type: .text, text: "Response")]
        )
        store.messages.append(otherMessage)

        try await store.sendPreparedAttempt(failedMessageId)

        #expect(
            store.messages.map(\.id) == [otherMessage.id, failedMessageId],
            "the retry replaces only the stale failed row and preserves unrelated rows"
        )
        #expect(
            store.messages.count { $0.id == failedMessageId } == 1,
            "the replacement retry row must not coexist with its stale predecessor"
        )
        #expect(store.lastFailedSend == nil)
        #expect(fake.requestLog.last?.params["messageId"] as? String == failedMessageId)
        let retriedRequest = try #require(fake.requestLog.last)
        let originalPayload = try JSONSerialization.data(withJSONObject: failedRequest.params, options: .sortedKeys)
        let retriedPayload = try JSONSerialization.data(withJSONObject: retriedRequest.params, options: .sortedKeys)
        #expect(originalPayload == retriedPayload)
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
        #expect(!store.isStreaming, "failed send settles only its optimistic thinking state")

        store.rollbackFailedSend()

        #expect(store.messages.isEmpty, "rollback removes the optimistic message")
        #expect(store.isStreaming == false, "rollback resets the thinking state")
        #expect(store.lastFailedSend != nil, "full recovery remains independent of the optimistic row")
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

    // MARK: - sendMessage messageMetadata threading (intent-hq/monorepo#1789)
}

extension ConversationStoreTests {
    @Test func sendMessageThreadsMessageMetadataToWire() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
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
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(agentId: "a", content: "hi", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["messageMetadata"] == nil, "plain sends stay untagged")
    }

    // MARK: - agentNotFound (missing-agent fallback)

    @Test func subscribeLiveChatNotFoundRaisesAgentNotFound() async {
        let fake = FakeConnectionManager()
        // chat.subscribe answers -32602 with data.code == "not-found" for a
        // nonexistent agent (docs/PROTOCOL.md §3.3/§9)
        fake.errorMap["chat.subscribe"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: gone",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.subscribeLiveChat(agentId: "gone", workspaceId: "w")

        #expect(store.agentNotFound, "a definitive not-found must raise agentNotFound")
    }

    @Test func subscribeLiveChatBare32602DoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        fake.errorMap["chat.subscribe"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "a -32602 without data.code == \"not-found\" must not raise agentNotFound")
    }

    @Test func subscribeLiveChatInvalidParams32602DoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.errorMap["chat.subscribe"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "Missing required parameter: agentId",
                NSError.intentErrorDataCodeKey: "invalid-params"
            ]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "data.code == \"invalid-params\" must not raise agentNotFound")
    }

    @Test func subscribeLiveChatTransientErrorDoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["chat.subscribe"] = NSError(
            domain: "WebSocket",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )
        let store = ConversationStore(connectionManager: fake)

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

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
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(!store.agentNotFound)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:deleted", "data": ["agentId": "a"]] as [String: Any]
        ])

        #expect(store.agentNotFound, "agent:deleted for the open agent must raise agentNotFound")
    }

    @Test func agentDeletedEventForOtherAgentDoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

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
}
