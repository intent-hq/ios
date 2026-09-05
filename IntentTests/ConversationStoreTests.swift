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
            lastMessageRole: nil,
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

    @Test func sendMessageThreadsMessageMetadataToWire() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(
            agentId: "a", content: "Q: x\nA: y", workspaceId: "w",
            messageMetadata: [
                "type": "question_answers",
                "answeredQuestionsMessageId": "msg-q1",
            ])

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

    // MARK: - agentNotFound (missing-agent fallback)

    @Test func fetchConversationNotFoundRaisesAgentNotFound() async {
        let fake = FakeConnectionManager()
        // agent.getConversation answers -32602 with data.code == "not-found" for a
        // nonexistent agent (docs/PROTOCOL.md §3.3/§9)
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "unknown agent id: gone",
                       NSError.intentErrorDataCodeKey: "not-found"])
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "gone", workspaceId: "w")

        #expect(store.agentNotFound, "a definitive not-found must raise agentNotFound")
    }

    @Test func fetchConversationBare32602DoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"])
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "a -32602 without data.code == \"not-found\" must not raise agentNotFound")
    }

    @Test func fetchConversationInvalidParams32602DoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId",
                       NSError.intentErrorDataCodeKey: "invalid-params"])
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "data.code == \"invalid-params\" must not raise agentNotFound")
    }

    @Test func fetchConversationTransientErrorDoesNotRaiseAgentNotFound() async {
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
        let store = ConversationStore(connectionManager: fake)

        await store.fetchConversation(agentId: "a", workspaceId: "w")

        #expect(!store.agentNotFound, "a transient transport error must not raise agentNotFound")
    }

    @Test func fetchAgentStreamingStateNotFoundRaisesAgentNotFound() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "unknown agent id: gone",
                       NSError.intentErrorDataCodeKey: "not-found"])
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
            "success": true, "dismissedQuestionsMessageId": "a1",
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.dismissQuestions(agentId: "a", messageId: "a1", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.dismissQuestions" })
        #expect(sent.params["agentId"] as? String == "a")
        #expect(sent.params["messageId"] as? String == "a1")
        #expect(sent.params["workspaceId"] as? String == "w")
        #expect(store.dismissedQuestionsMessageId == "a1")
    }

    @Test func dismissQuestionsFallsBackToRequestedIdWhenResultOmitsMarker() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.dismissQuestions"] = ["success": true] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.dismissQuestions(agentId: "a", messageId: "a1", workspaceId: "w")

        #expect(store.dismissedQuestionsMessageId == "a1")
    }

    @Test func failedDismissRollsBackMarkerAndRethrows() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32000)
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.dismissQuestions(agentId: "a", messageId: "a1", workspaceId: "w")
        }

        #expect(store.dismissedQuestionsMessageId == nil,
                "a failed dismiss must roll the optimistic marker back so the wizard re-pends")
    }

    @Test func dismissQuestionsRaisesMarkerOptimisticallyBeforeRpcReturns() async throws {
        // PR #86 review: the marker must be raised BEFORE the RPC resolves so
        // the wizard unmounts immediately — no in-flight window where a Send
        // or second Dismiss can race the same question message.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.dismissQuestions"] = ["success": true] as [String: Any]
        fake.delayMap["agent.dismissQuestions"] = 50_000_000
        let store = ConversationStore(connectionManager: fake)

        let inFlight = Task { try await store.dismissQuestions(
            agentId: "a", messageId: "a1", workspaceId: "w") }
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(store.dismissedQuestionsMessageId == "a1",
                "the marker is raised optimistically while the RPC is in flight")
        try await inFlight.value
        #expect(store.dismissedQuestionsMessageId == "a1")
    }

    @Test func failedDismissRollbackPreservesConcurrentMarkerUpdate() async throws {
        // If another client's dismissal lands (agent:updated push) while our
        // failing RPC is in flight, the rollback must not clobber it.
        let fake = FakeConnectionManager()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32000)
        fake.delayMap["agent.dismissQuestions"] = 50_000_000
        let store = ConversationStore(connectionManager: fake)

        let inFlight = Task { try await store.dismissQuestions(
            agentId: "a", messageId: "a1", workspaceId: "w") }
        try await Task.sleep(nanoseconds: 10_000_000)
        store.dismissedQuestionsMessageId = "a2"

        await #expect(throws: (any Error).self) { try await inFlight.value }
        #expect(store.dismissedQuestionsMessageId == "a2",
                "rollback must not clobber a marker moved while the RPC was in flight")
    }

    @Test func agentUpdatedEventAppliesDismissalMarkerPushStyle() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "dismissedQuestionsMessageId": "a1"]] as [String: Any]
        ])

        #expect(store.dismissedQuestionsMessageId == "a1",
                "a dismissal from another client must retire the wizard here too")
    }

    @Test func agentUpdatedEventForOtherAgentIsIgnored() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "someone-else",
                               "dismissedQuestionsMessageId": "x1"]] as [String: Any]
        ])

        #expect(store.dismissedQuestionsMessageId == nil)
    }

    @Test func agentUpdatedEventWithoutMarkerLeavesStateUntouched() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        store.dismissedQuestionsMessageId = "a1"

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "lastSeenMessageId": "m9"]] as [String: Any]
        ])

        #expect(store.dismissedQuestionsMessageId == "a1",
                "an unrelated agent:updated must not clear the marker")
    }

    @Test func fetchAgentStreamingStateRestoresDismissalMarkerFromMetadata() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "Test",
                "metadata": ["dismissedQuestionsMessageId": "a1"],
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.dismissedQuestionsMessageId == "a1",
                "the daemon-persisted marker must survive reload (AgentLite metadata)")
    }

    @Test func resetClearsDismissalMarker() {
        let store = ConversationStore()
        store.dismissedQuestionsMessageId = "a1"
        store.reset()
        #expect(store.dismissedQuestionsMessageId == nil)
    }

    // MARK: - Pending-questions marker (PROTOCOL §5.5 pendingQuestionsMessageId)

    @Test func pendingMarkerStartsNil() {
        let store = ConversationStore()
        #expect(store.pendingQuestionsMessageId == nil)
    }

    @Test func fetchAgentStreamingStateRestoresPendingMarkerFromMetadata() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "Test",
                "metadata": ["pendingQuestionsMessageId": "a1"],
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.pendingQuestionsMessageId == "a1")
    }

    @Test func fetchAgentStreamingStateRaiseOnlyStillAppliesPendingMarker() async {
        // The agent:idle refresh runs raiseOnly — the marker must still land,
        // since that refresh is what populates it when the asking turn ends.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "Test", "isStreaming": false,
                "metadata": ["pendingQuestionsMessageId": "a1"],
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true)

        #expect(store.pendingQuestionsMessageId == "a1")
    }

    @Test func fetchAgentStreamingStatePreservesWrittenEmptyPendingMarker() async {
        // Three-state rule: "" (nothing pending) must not be coerced to nil
        // (legacy fallback), or a question-bearing tail would re-pend.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "Test",
                "metadata": ["pendingQuestionsMessageId": ""],
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)
        store.pendingQuestionsMessageId = "a1"

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.pendingQuestionsMessageId == "")
    }

    @Test func fetchAgentStreamingStateWithoutPendingMarkerLeavesItUntouched() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "Test",
                "metadata": ["dismissedQuestionsMessageId": "a0"],
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)
        store.pendingQuestionsMessageId = "a1"

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.pendingQuestionsMessageId == "a1",
                "an absent field is not a clear — only \"\" is")
    }

    @Test func agentUpdatedEventAppliesPendingMarkerPushStyle() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "pendingQuestionsMessageId": "a1"]] as [String: Any]
        ])
        #expect(store.pendingQuestionsMessageId == "a1")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "pendingQuestionsMessageId": ""]] as [String: Any]
        ])
        #expect(store.pendingQuestionsMessageId == "",
                "the daemon clearing the marker to \"\" must land push-style")
    }

    @Test func agentUpdatedEventDuringInitialFetchIsAppliedNotDropped() async throws {
        // Regression (PR #210 review): the isLoading buffer only replays
        // user-message/stream events, so a marker clear pushed while the
        // initial agent.getConversation was in flight used to be dropped —
        // the wizard then re-pended on the stale agent.get marker. Session
        // metadata pushes bypass the buffer and land immediately.
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.getConversation")
        let store = ConversationStore(connectionManager: fake)
        store.pendingQuestionsMessageId = "a1"

        let fetch = Task { await store.fetchConversation(agentId: "a", workspaceId: "w") }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "pendingQuestionsMessageId": "",
                               "lastSeenMessageId": "m9"]] as [String: Any]
        ])
        #expect(store.pendingQuestionsMessageId == "",
                "the marker clear lands while the fetch is still in flight")
        #expect(store.lastSeenMessageId == "m9")

        fake.resolvePending("agent.getConversation", with: ["messages": []] as [String: Any])
        await fetch.value

        #expect(!store.isLoading)
        #expect(store.pendingQuestionsMessageId == "",
                "settling the fetch does not revert the pushed marker")
        #expect(store.lastSeenMessageId == "m9")
    }

    @Test func staleAgentGetReplyDoesNotOverwriteMarkersPushedWhileInFlight() async throws {
        // Regression: an agent.get reply applied unconditionally used to
        // revert a marker that an agent:updated push moved after the request
        // started (e.g. a newer question-bearing turn's marker replaced by the
        // previous marker the daemon captured before it).
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "pendingQuestionsMessageId": "a2",
                               "dismissedQuestionsMessageId": "a1",
                               "lastSeenMessageId": "m9"]] as [String: Any]
        ])

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a", "name": "A", "isStreaming": true,
                "metadata": ["pendingQuestionsMessageId": "a1",
                             "dismissedQuestionsMessageId": "a0",
                             "lastSeenMessageId": "m3"],
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.pendingQuestionsMessageId == "a2",
                "the stale reply must not revert the pushed pending marker")
        #expect(store.dismissedQuestionsMessageId == "a1",
                "the stale reply must not revert the pushed dismissal marker")
        #expect(store.lastSeenMessageId == "m9",
                "the stale reply must not revert the pushed seen marker")
        #expect(store.isStreaming,
                "streaming state is still applied from the reply")
    }

    @Test func agentGetReplyStillAppliesMarkersWhenNoPushIntervened() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a", "name": "A",
                "metadata": ["pendingQuestionsMessageId": "a1",
                             "dismissedQuestionsMessageId": "a0",
                             "lastSeenMessageId": "m3"],
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.pendingQuestionsMessageId == "a1")
        #expect(store.dismissedQuestionsMessageId == "a0")
        #expect(store.lastSeenMessageId == "m3")
    }

    @Test func agentGetReplyStillAppliesMarkersAfterUnrelatedAgentUpdated() async throws {
        // An agent:updated for another agent is filtered out before the
        // metadata handler, so it must not make our in-flight reply look stale.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "someone-else",
                               "pendingQuestionsMessageId": "x1"]] as [String: Any]
        ])

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a", "name": "A",
                "metadata": ["pendingQuestionsMessageId": "a1"],
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.pendingQuestionsMessageId == "a1")
    }

    @Test func turnBoundaryBufferedDuringInitialFetchTriggersOneMarkerRefresh() async throws {
        // Regression (PR #210 review): agent:idle / agent:status-changed that
        // land while isLoading are buffered but never replayed, so the
        // raiseOnly agent.get that raises the pending-questions marker at the
        // asking turn's end was skipped for a turn ending mid-load — the marker
        // stayed nil (legacy fallback) and the wizard was not sticky.
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.getConversation")
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "A",
                "metadata": ["pendingQuestionsMessageId": "a1"],
            ] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        let fetch = Task { await store.fetchConversation(agentId: "a", workspaceId: "w") }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:status-changed",
                      "data": ["agentId": "a", "status": "idle"]] as [String: Any]
        ])
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:idle", "data": ["agentId": "a"]] as [String: Any]
        ])
        #expect(store.pendingQuestionsMessageId == nil,
                "turn boundaries are buffered while the fetch is in flight")

        fake.resolvePending("agent.getConversation", with: ["messages": []] as [String: Any])
        await fetch.value
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!store.isLoading)
        #expect(store.pendingQuestionsMessageId == "a1",
                "the buffered turn boundary still refreshes the marker after load")
        #expect(fake.requestLog.filter { $0.method == "agent.get" }.count == 1,
                "one refresh regardless of how many boundaries were buffered")
    }

    @Test func agentUpdatedEventWithoutPendingMarkerLeavesItUntouched() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        store.pendingQuestionsMessageId = "a1"

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "lastSeenMessageId": "m9"]] as [String: Any]
        ])

        #expect(store.pendingQuestionsMessageId == "a1")
    }

    @Test func agentUpdatedEventForOtherAgentDoesNotMovePendingMarker() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "someone-else",
                               "pendingQuestionsMessageId": "x1"]] as [String: Any]
        ])

        #expect(store.pendingQuestionsMessageId == nil)
    }

    @Test func resetClearsPendingMarker() {
        let store = ConversationStore()
        store.pendingQuestionsMessageId = "a1"
        store.reset()
        #expect(store.pendingQuestionsMessageId == nil)
    }

    // MARK: - Marked question recovery (aroundMessageId seek, Phase 2)

    /// A question-bearing assistant row as the daemon serves it.
    private func questionRow(id: String) -> [String: Any] {
        [
            "id": id, "role": "assistant", "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": "Which one?"]],
        ]
    }

    private func pushMarker(_ store: ConversationStore, _ markerId: String) {
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "pendingQuestionsMessageId": markerId]] as [String: Any]
        ])
    }

    private func seekRequests(_ fake: FakeConnectionManager) -> [[String: Any]] {
        fake.paramsForMethod("agent.getConversation").filter { $0["aroundMessageId"] != nil }
    }

    @Test func markerNamingMissingRowIssuesOneAroundMessageIdSeek() async throws {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["agent.getConversation"] = [
            ["messages": []] as [String: Any],
            ["messages": [questionRow(id: "q1")]] as [String: Any],
        ]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        #expect(store.pendingQuestionRecovery == nil)

        pushMarker(store, "q1")
        #expect(store.pendingQuestionRecovery?.status == .loading,
                "fails closed while the seek is in flight")
        try await Task.sleep(nanoseconds: 100_000_000)

        let seeks = seekRequests(fake)
        #expect(seeks.count == 1, "exactly one seek per marker id")
        #expect(seeks.first?["aroundMessageId"] as? String == "q1")
        #expect(seeks.first?["limit"] as? Int == 1)
        #expect(seeks.first?["projection"] as? String == "slim")
        #expect(seeks.first?["agentId"] as? String == "a")
        #expect(seeks.first?["workspaceId"] as? String == "w")
        #expect(store.pendingQuestionRecovery?.messageId == "q1")
        #expect(store.pendingQuestionRecovery?.status == .found)
        #expect(store.pendingQuestionRecovery?.message?.id == "q1")

        // A later reconcile for the same marker never re-seeks.
        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(seekRequests(fake).count == 1)
    }

    @Test func markerNamingResidentRowIssuesNoSeek() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": [questionRow(id: "q1")]]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(seekRequests(fake).isEmpty, "a resident row is never seeked")
        #expect(store.pendingQuestionRecovery == nil)
    }

    @Test func seekPageWithoutTheRowSettlesNotFound() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(store.pendingQuestionRecovery?.status == .notFound)
        #expect(store.pendingQuestionRecovery?.message == nil)
    }

    @Test func seekUnknownMessageId32602SettlesNotFoundWithoutRetry() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        // PROTOCOL §5.5: an unknown aroundMessageId is -32602 naming the id
        // (no data.code == "not-found" — the agent itself exists).
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "unknown message id: q1"])

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(seekRequests(fake).count == 1, "-32602 is terminal — no retry")
        #expect(store.pendingQuestionRecovery?.status == .notFound)
        #expect(!store.agentNotFound, "an unknown message id is not a deleted agent")
    }

    @Test func seekTransportErrorRetriesThenSettlesFound() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.errorQueueMap["agent.getConversation"] = [
            NSError(domain: "WebSocket", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Request timed out"]),
        ]
        fake.responseMap["agent.getConversation"] = ["messages": [questionRow(id: "q1")]]

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(seekRequests(fake).count == 1)
        #expect(store.pendingQuestionRecovery?.status == .loading,
                "still loading while waiting for the 250 ms retry")

        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(seekRequests(fake).count == 2, "one retry after the transport error")
        #expect(store.pendingQuestionRecovery?.status == .found)
        #expect(store.pendingQuestionRecovery?.message?.id == "q1")
    }

    @Test func seekExhaustedRetriesSettlesError() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 1_600_000_000)

        #expect(seekRequests(fake).count == 3, "initial attempt + 250 ms + 1 s retries")
        #expect(store.pendingQuestionRecovery?.status == .error)
    }

    @Test func markerClearedMidFlightCancelsSeekAndDropsState() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(seekRequests(fake).count == 1)
        #expect(store.pendingQuestionRecovery?.status == .loading)

        pushMarker(store, "")
        #expect(store.pendingQuestionRecovery == nil, "the marker clear drops the state")

        fake.resolvePending("agent.getConversation",
                            with: ["messages": [questionRow(id: "q1")]] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.pendingQuestionRecovery == nil,
                "a late reply for the cancelled seek never settles state")
    }

    @Test func markerReplacedMidFlightRestartsSeekForTheNewId() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 50_000_000)
        pushMarker(store, "q2")
        try await Task.sleep(nanoseconds: 50_000_000)

        let seeks = seekRequests(fake)
        #expect(seeks.map { $0["aroundMessageId"] as? String } == ["q1", "q2"])
        #expect(store.pendingQuestionRecovery?.messageId == "q2")
        #expect(store.pendingQuestionRecovery?.status == .loading)
    }

    @Test func rowArrivingInTranscriptWhileSeekInFlightSettlesFoundFromResidentRow() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        store.setTestChatChannel(subscriptionId: "sub-chat")
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.pendingQuestionRecovery?.status == .loading)

        store.handleStreamEvent("subscription.push", params: [
            "subscriptionId": "sub-chat", "kind": "snapshot", "seq": 0,
            "snapshot": ["agentId": "a", "messages": [questionRow(id: "q1")]] as [String: Any],
        ] as [String: Any])

        #expect(store.messages.map(\.id) == ["q1"])
        #expect(store.pendingQuestionRecovery?.status == .found,
                "the resident row settles the in-flight seek")
        #expect(store.pendingQuestionRecovery?.message?.id == "q1")
    }

    @Test func markerPushedDuringInitialFetchSeeksOnceTheFetchSettles() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.getConversation")
        let store = ConversationStore(connectionManager: fake)

        let fetch = Task { await store.fetchConversation(agentId: "a", workspaceId: "w") }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isLoading)

        pushMarker(store, "q1")
        #expect(store.pendingQuestionRecovery == nil, "no seek while the initial fetch is in flight")

        fake.pendingMethods.remove("agent.getConversation")
        fake.responseMap["agent.getConversation"] = ["messages": [questionRow(id: "q1")]]
        fake.resolvePending("agent.getConversation", with: ["messages": []] as [String: Any])
        await fetch.value
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(seekRequests(fake).count == 1)
        #expect(store.pendingQuestionRecovery?.status == .found)
    }

    @Test func resetClearsPendingQuestionRecovery() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")
        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.pendingQuestionRecovery != nil)

        store.reset()

        #expect(store.pendingQuestionRecovery == nil)
    }

    @Test func agentDeletedEventDropsPendingQuestionRecovery() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")
        pushMarker(store, "q1")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.pendingQuestionRecovery != nil)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:deleted", "data": ["agentId": "a"]] as [String: Any]
        ])

        #expect(store.agentNotFound)
        #expect(store.pendingQuestionRecovery == nil)
    }

    @Test func sendMessageMirrorsMessageMetadataOntoOptimisticRow() async throws {
        // The optimistic user row carries the answer tag so the wizard gate
        // sees the set as answered before the daemon clears the marker.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(
            agentId: "a", content: "Q: x\nA: y", workspaceId: "w",
            messageMetadata: [
                "type": "question_answers",
                "answeredQuestionsMessageId": "msg-q1",
            ])

        let row = try #require(store.messages.last)
        #expect(row.role == .user)
        #expect(row.metadata?["type"]?.stringValue == "question_answers")
        #expect(row.answeredQuestionsMessageId == "msg-q1")
    }

    @Test func sendMessageLeavesOptimisticRowMetadataNilWhenAbsent() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(agentId: "a", content: "hi", workspaceId: "w")

        let row = try #require(store.messages.last)
        #expect(row.metadata == nil)
        #expect(row.answeredQuestionsMessageId == nil)
    }

    @Test func queuedSendSeedsLocalQueueWithTaggedEntry() async throws {
        // When the daemon auto-queues the wizard's answer (turn-startup race),
        // the optimistic tagged row is removed; the queued entry — carrying
        // the same question_answers tag — must be visible locally from the
        // send result, before any agent:queue:updated lands, so the wizard
        // gate still sees the marked set as answered.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [
            "success": true, "queued": true,
            "queuedMessage": [
                "id": "q-1", "content": "Q: x\nA: y", "queuedAt": "2026-01-01T00:00:00Z",
                "position": 0,
                "messageMetadata": [
                    "type": "question_answers", "answeredQuestionsMessageId": "msg-q1",
                ],
            ] as [String: Any],
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(
            agentId: "a", content: "Q: x\nA: y", workspaceId: "w",
            messageMetadata: [
                "type": "question_answers",
                "answeredQuestionsMessageId": "msg-q1",
            ])

        #expect(store.messages.isEmpty, "the optimistic row moves to the queue panel")
        #expect(store.queuedMessages.map(\.id) == ["q-1"])
        #expect(store.queuedMessages.first?.answeredQuestionsMessageId == "msg-q1")

        // An agent:queue:updated that raced ahead of the result is not duplicated.
        try await store.sendMessage(
            agentId: "a", content: "Q: x\nA: y", workspaceId: "w",
            messageMetadata: [
                "type": "question_answers",
                "answeredQuestionsMessageId": "msg-q1",
            ])
        #expect(store.queuedMessages.count == 1)
    }

    @Test func rollbackFailedSendRemovesTaggedOptimisticRow() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32000)
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(
                agentId: "a", content: "Q: x\nA: y", workspaceId: "w",
                messageMetadata: [
                    "type": "question_answers",
                    "answeredQuestionsMessageId": "msg-q1",
                ])
        }
        #expect(store.messages.last?.answeredQuestionsMessageId == "msg-q1")

        store.rollbackFailedSend()

        #expect(store.messages.isEmpty, "the tagged row is removed so the set re-pends")
    }

    // MARK: - Seen marker (agent.markSeen, PROTOCOL §5.5)

    @Test func fetchAgentStreamingStateRestoresSeenMarkerFromMetadata() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "Test",
                "metadata": ["lastSeenMessageId": "m1"],
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.lastSeenMessageId == "m1",
                "the daemon-persisted seen marker must survive reload (AgentLite metadata)")
    }

    @Test func fetchAgentStreamingStateRaiseOnlyStillAppliesSeenMarker() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a", "name": "Test",
                "metadata": ["lastSeenMessageId": "m1"],
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true)

        #expect(store.lastSeenMessageId == "m1",
                "raiseOnly only gates isStreaming — the marker refresh applies on both paths")
    }

    @Test func agentUpdatedEventAppliesSeenMarkerPushStyle() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "a",
                               "lastSeenMessageId": "m9"]] as [String: Any]
        ])

        #expect(store.lastSeenMessageId == "m9",
                "a marker move from another client must converge here push-style")
    }

    @Test func agentUpdatedEventForOtherAgentDoesNotMoveSeenMarker() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:updated",
                      "data": ["agentId": "someone-else",
                               "lastSeenMessageId": "m9"]] as [String: Any]
        ])

        #expect(store.lastSeenMessageId == nil)
    }

    @Test func resetClearsSeenMarker() {
        let store = ConversationStore()
        store.lastSeenMessageId = "m1"
        store.reset()
        #expect(store.lastSeenMessageId == nil)
    }

    @Test func markSeenSendsNewestPersistedMessageIdAndAdoptsResult() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.markSeen"] = [
            "success": true, "lastSeenMessageId": "m2",
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.messages = [
            ConversationMessage(id: "m1", role: .user),
            ConversationMessage(id: "m2", role: .assistant),
        ]

        await store.markSeen(agentId: "a", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.markSeen" })
        #expect(sent.params["agentId"] as? String == "a")
        #expect(sent.params["messageId"] as? String == "m2")
        #expect(sent.params["workspaceId"] as? String == "w")
        #expect(store.lastSeenMessageId == "m2",
                "the confirmed marker from the result is adopted")
    }

    @Test func markSeenSkipsStreamingRows() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.markSeen"] = [
            "success": true, "lastSeenMessageId": "m1",
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.messages = [
            ConversationMessage(id: "m1", role: .user),
            ConversationMessage(id: "m2", role: .assistant, isStreaming: true),
        ]

        await store.markSeen(agentId: "a", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.markSeen" })
        #expect(sent.params["messageId"] as? String == "m1",
                "streaming rows are never eligible — the marker must name a persisted message")
    }

    @Test func markSeenNoopWithoutPersistedMessages() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.messages = [
            ConversationMessage(id: "m1", role: .assistant, isStreaming: true)
        ]

        await store.markSeen(agentId: "a", workspaceId: "w")

        #expect(!fake.didCallMethod("agent.markSeen"))
    }

    @Test func markSeenDedupesRepeatCallsForSameTarget() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.markSeen"] = ["success": true] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.messages = [ConversationMessage(id: "m1", role: .assistant)]

        await store.markSeen(agentId: "a", workspaceId: "w")
        await store.markSeen(agentId: "a", workspaceId: "w")

        #expect(fake.paramsForMethod("agent.markSeen").count == 1,
                "re-triggering the same target must not re-send")
    }

    @Test func markSeenSkipsWhenTargetEqualsCurrentMarker() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.messages = [ConversationMessage(id: "m1", role: .assistant)]
        store.lastSeenMessageId = "m1"

        await store.markSeen(agentId: "a", workspaceId: "w")

        #expect(!fake.didCallMethod("agent.markSeen"))
    }

    @Test func markSeenRollsBackDedupeOnFailureSoLaterTriggerRetries() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.markSeen"] = NSError(domain: "WebSocket", code: -32000)
        let store = ConversationStore(connectionManager: fake)
        store.messages = [ConversationMessage(id: "m1", role: .assistant)]

        await store.markSeen(agentId: "a", workspaceId: "w")
        #expect(store.lastSeenMessageId == nil, "a failed call must not move the marker")

        fake.errorMap.removeValue(forKey: "agent.markSeen")
        fake.responseMap["agent.markSeen"] = [
            "success": true, "lastSeenMessageId": "m1",
        ] as [String: Any]
        await store.markSeen(agentId: "a", workspaceId: "w")

        #expect(fake.paramsForMethod("agent.markSeen").count == 2,
                "the dedupe record is rolled back on failure so a later trigger retries")
        #expect(store.lastSeenMessageId == "m1")
    }

    @Test func markSeenSendsNewTargetAfterMarkerAdvances() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.markSeen"] = ["success": true] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.messages = [ConversationMessage(id: "m1", role: .assistant)]

        await store.markSeen(agentId: "a", workspaceId: "w")
        store.messages.append(ConversationMessage(id: "m2", role: .assistant))
        await store.markSeen(agentId: "a", workspaceId: "w")

        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 2)
        #expect(params.last?["messageId"] as? String == "m2")
    }
}

