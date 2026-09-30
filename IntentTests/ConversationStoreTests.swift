import Foundation
@testable import Intent
import Synchronization
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

    @Test(arguments: [false, true])
    func knownNotSentRetryReusesOriginalPayloadAndReplacesOnlyItsRow(inline: Bool) async throws {
        let fake = FakeConnectionManager()
        fake.errorQueueMap["agent.sendMessage"] = [
            DiagnosticErrorOwnership.attaching(
                to: NSError(domain: "WebSocket", code: -4),
                failure: DiagnosticFailure(origin: .localRequest, classification: .notConnected)
            )
        ]
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        let store = ConversationStore(connectionManager: fake)
        let images: OutgoingImagePayload = inline
            ? .inline([["type": "image", "mimeType": "image/jpeg", "data": "c3ludGhldGljLWltYWdl"]])
            : .attachments([["type": "image", "attachmentId": "image-1"]])

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(
                agentId: "a",
                content: "Test message",
                workspaceId: "w",
                imagePayload: images,
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

extension ConversationStoreTests {
    func bindRecoveryStore(_ store: ConversationStore, fake: FakeConnectionManager, source: String) async {
        store.bindAgent("a")
        if source == "delta" {
            fake.stubChatSnapshot()
            await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        }
    }

    func deliverRecoveryDelta(
        _ rowId: String,
        store: ConversationStore,
        correlation: String? = nil,
        seq: Int = 1,
        updated: Bool = false
    ) {
        var entity: [String: Any] = [
            "messageId": rowId, "role": "user", "streamingComplete": true,
            "block": ["id": "\(rowId):0", "type": "text", "text": "hello"]
        ]
        if let correlation { entity["appMessageId"] = correlation }
        store.handleStreamEvent("subscription.push", params: [
            "subscriptionId": "sub-1", "kind": "delta", "seq": seq,
            "delta": [
                "added": updated ? [] : [entity], "updated": updated ? [entity] : [], "removedIds": []
            ]
        ])
    }

    @Test(arguments: [false, true])
    func acceptedRPCThenCorrelatedLiveDeltaReconcilesOnce(existingRow: Bool) async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        let send = Task { try await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        let id = try #require(store.sendAttempts.first?.id)
        fake.resolvePending("agent.sendMessage", with: ["success": true, "queued": false, "messageId": id])
        try await send.value
        #expect(store.sendAttempts.first?.status == .accepted)
        #expect(store.messages.map(\.id) == [id])
        if existingRow {
            deliverRecoveryDelta("server-row", store: store)
            #expect(store.messages.map(\.id) == [id, "server-row"], "absent correlation cannot guess the owner")
        }
        let seq = existingRow ? 2 : 1
        deliverRecoveryDelta("server-row", store: store, correlation: id, seq: seq, updated: existingRow)
        #expect(store.messages.map(\.id) == ["server-row"])
        #expect(store.messages.last?.appMessageId == id)
        #expect(store.sendAttempts.first?.confirmedMessageId == "server-row")
        // Duplicate sequence, then a fresh update omitting optional correlation.
        deliverRecoveryDelta("server-row", store: store, correlation: id, seq: seq)
        deliverRecoveryDelta("server-row", store: store, seq: seq + 1, updated: true)
        await deliverRecoveryRow("late-queue", source: "queue", store: store, fake: fake, correlation: id)
        #expect(store.messages.map(\.id) == ["server-row"])
        #expect(store.messages.last?.appMessageId == id)
        #expect(store.messages.last?.contentBlocks.count == 1)
        #expect(store.sendAttempts.first?.status == .accepted)
        #expect(store.sendAttempts.first?.confirmedMessageId == "server-row")
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test(arguments: ["topLevel", "queue", "delta"], ["direct", "confirmed", "same", "ambiguous", "sharedConfirmed"])
    func recoveryWithoutCorrelationRequiresOneDistinctAttempt(source: String, identity: String) async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        await bindRecoveryStore(store, fake: fake, source: source)
        let stopped = Mutex<[URL]>([])
        let url = URL(fileURLWithPath: "/tmp/fallback.txt")
        let id = store.beginSendAttempt(
            agentId: "a",
            content: "original",
            workspaceId: "w",
            files: [PendingFile(url: url, displayName: "fallback.txt", size: 0)],
            fileAccess: ConversationSendFileAccess(urls: [url]) { url in
                stopped.withLock { $0.append(url) }
            }
        )
        store.prepareSendAttempt(id, imagePayload: .none, filePayload: .attachments([["type": "file", "attachmentId": "file-1"]]))
        let rowId = identity == "confirmed" || identity == "sharedConfirmed" ? "server-row" : id
        let initiallyQueued = ["confirmed", "same", "sharedConfirmed"].contains(identity)
        let ambiguous = identity == "ambiguous" || identity == "sharedConfirmed"
        let queuedReply: [String: Any] = ["success": true, "queued": true, "queuedMessage": queuedSend(rowId)]
        fake.responseMap["agent.sendMessage"] = queuedReply
        if !initiallyQueued { fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2) }
        try? await store.sendPreparedAttempt(id)
        fake.errorMap["agent.sendMessage"] = ambiguous ? nil : NSError(domain: "WebSocket", code: -2)
        try? await store.sendMessage(agentId: "a", content: "other", workspaceId: "w")
        let initialStatus: ConversationSendAttempt.Status = initiallyQueued ? .queued : .unconfirmed
        #expect(store.sendAttempts[0].status == initialStatus)
        #expect(stopped.withLock { $0 } == (initiallyQueued ? [url] : []))
        await deliverRecoveryRow(rowId, source: source, store: store, fake: fake)
        let confirmed: ConversationSendAttempt.Status = source == "queue" ? .queued : .accepted
        #expect(store.sendAttempts[0].status == (ambiguous ? initialStatus : confirmed))
        #expect(store.sendAttempts[0].confirmedMessageId == (initiallyQueued || !ambiguous ? rowId : nil))
        #expect(store.sendAttempts[1].status == (ambiguous ? .queued : .unconfirmed))
        let retainsResources = ambiguous && !initiallyQueued
        #expect(store.sendAttempts[0].files.count == (retainsResources ? 1 : 0))
        #expect((store.sendAttempts[0].fileAccess != nil) == retainsResources)
        #expect(stopped.withLock { $0 } == (retainsResources ? [] : [url]))
        var payload: [String: Any] = [:]
        store.sendAttempts[0].filePayload.apply(to: &payload)
        #expect((payload["fileBlocks"] != nil) == retainsResources)
        #expect(fake.paramsForMethod("agent.sendMessage").count == 2)
    }
}
