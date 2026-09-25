import Foundation
@testable import Intent
import Synchronization
import Testing

extension ConversationStoreTests {
    private func sentRow(_ id: String, appMessageId: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "role": "user", "contentBlocks": [["type": "text", "text": "hello"]]]
        if let appMessageId { row["appMessageId"] = appMessageId }
        return row
    }

    func queuedSend(_ id: String, originalId: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "content": "hello", "queuedAt": "2026-09-24T00:00:00Z", "position": 0]
        if let originalId { row["messageMetadata"] = ["userAppMessageId": originalId] }
        return row
    }

    @Test(arguments: [-32_603, -32_602, -2, -3, -4])
    func sendErrorsRetainPayloadWithoutClaimingRejection(code: Int) async throws {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: code)
        let store = ConversationStore(connectionManager: fake)
        await #expect(throws: (any Error).self) {
            try await store.sendMessage(
                agentId: "a",
                content: "hello",
                workspaceId: "w",
                imagePayload: .attachments([["type": "image", "attachmentId": "image-1"]]),
                filePayload: .attachments([["type": "file", "attachmentId": "file-1", "fileName": "notes.txt"]]),
                messageMetadata: .fields(["type": "question_answers", "answeredQuestionsMessageId": "question-1"])
            )
        }
        let attempt = try #require(store.lastFailedSend)
        var params: [String: Any] = [:]
        attempt.imagePayload.apply(to: &params)
        attempt.filePayload.apply(to: &params)
        attempt.messageMetadata.apply(to: &params)
        #expect(attempt.status == .unconfirmed)
        #expect(!attempt.canRetry)
        #expect(attempt.content == "hello")
        #expect((params["imageBlocks"] as? [[String: Any]])?.first?["attachmentId"] as? String == "image-1")
        #expect((params["fileBlocks"] as? [[String: Any]])?.first?["attachmentId"] as? String == "file-1")
        #expect((params["messageMetadata"] as? [String: Any])?["answeredQuestionsMessageId"] as? String == "question-1")
        #expect(!store.isStreaming)
        await #expect(throws: ConversationSendError.self) { try await store.sendPreparedAttempt(attempt.id) }
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1, "uncertain delivery cannot be replayed")
    }

    @Test func sameTextDifferentAttachmentsAndMetadataKeepSeparateAttempts() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2)
        let store = ConversationStore(connectionManager: fake)
        for suffix in ["first", "second"] {
            try? await store.sendMessage(
                agentId: "a",
                content: "",
                workspaceId: "w",
                imagePayload: .attachments([["type": "image", "attachmentId": "image-\(suffix)"]]),
                filePayload: .attachments([["type": "file", "attachmentId": "file-\(suffix)"]]),
                messageMetadata: .fields(["selection": suffix])
            )
        }
        #expect(store.sendAttempts.count == 2)
        #expect(Set(store.sendAttempts.map(\.id)).count == 2)
        #expect(store.sendAttempts.allSatisfy { $0.status == .unconfirmed })
        let requests = fake.paramsForMethod("agent.sendMessage")
        #expect(requests.count == 2)
        for (index, suffix) in ["first", "second"].enumerated() {
            let attempt = store.sendAttempts[index]
            #expect(requests[index]["userAppMessageId"] as? String == attempt.id)
            #expect(attempt.messageMetadata.optimisticFields["selection"]?.stringValue == suffix)
        }
        store.messages = []
        #expect(store.sendAttempts.count == 2, "transcript replacement is not recovery deletion")
    }

    @Test func authoritativeAcceptanceBeforeTimeoutWinsWithoutAnotherSend() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        let send = Task { try await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        let id = try #require(store.sendAttempts.first?.id)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 1,
            snapshot: [sentRow(id)],
            delta: nil
        ))
        fake.failPending("agent.sendMessage", with: NSError(domain: "WebSocket", code: -2))
        try await send.value
        #expect(store.sendAttempts.first?.status == .accepted)
        #expect(store.lastFailedSend == nil)
        #expect(store.messages.map(\.id) == [id])
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func queueEchoBeforeTimeoutConfirmsOriginalAttempt() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        let store = ConversationStore(connectionManager: fake)
        store.bindAgent("a")
        store.isStreaming = true
        let send = Task { try await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        let id = try #require(store.sendAttempts.first?.id)
        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:queue:updated",
                "data": ["agentId": "a", "queue": [queuedSend("queue-1", originalId: id)]]
            ]
        ])
        fake.failPending("agent.sendMessage", with: NSError(domain: "WebSocket", code: -2))
        try await send.value
        #expect(store.sendAttempts.first?.status == .queued)
        #expect(store.sendAttempts.first?.confirmedMessageId == "queue-1")
        #expect(store.messages.isEmpty)
        #expect(store.isStreaming, "auto-queueing does not stop the real running turn")
    }

    @Test func failedSendAndRollbackPreserveNewRealStream() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        let store = ConversationStore(connectionManager: fake)
        store.bindAgent("a")
        let send = Task { try? await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:stream:start", "data": ["agentId": "a"]]
        ])
        fake.failPending("agent.sendMessage", with: NSError(domain: "WebSocket", code: -32_603))
        await send.value
        store.rollbackFailedSend()
        #expect(store.isStreaming)
        #expect(store.messages.isEmpty)
        #expect(store.lastFailedSend?.status == .unconfirmed)
    }

    @Test func inspectionCannotConfirmFromOptimisticRowOrAbsentMalformedReads() async throws {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2)
        let store = ConversationStore(connectionManager: fake)
        try? await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w")
        let id = try #require(store.lastFailedSend?.id)
        let reads: [[String: Any]] = [
            [:], ["messages": []], ["messages": [["id": id]]],
            ["messages": [["id": id, "role": "user"]]], ["messages": [sentRow("other")]]
        ]
        for response in reads {
            fake.responseMap["agent.getConversation"] = response
            fake.responseMap["agent.getQueue"] = ["queue": [["id": id]]]
            await store.inspectSendAttempt(id)
            #expect(store.lastFailedSend?.status == .unconfirmed)
            #expect(store.lastFailedSend?.isCheckingStatus == false)
            #expect(store.lastFailedSend?.canRetry == false)
        }
        fake.errorMap["agent.getConversation"] = NSError(domain: "WebSocket", code: -32_602)
        fake.responseMap["agent.getQueue"] = ["queue": []]
        await store.inspectSendAttempt(id)
        #expect(store.lastFailedSend?.status == .unconfirmed)
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func inspectionFindsQueuedAcceptanceThenDrainedRowByCorrelation() async throws {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2)
        let store = ConversationStore(connectionManager: fake)
        try? await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w")
        let id = try #require(store.lastFailedSend?.id)
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.getQueue"] = ["queue": [queuedSend("queue-1", originalId: id)]]
        await store.inspectSendAttempt(id)
        #expect(store.sendAttempts.first?.status == .queued)
        #expect(store.messages.isEmpty)
        fake.stubChatSnapshot(messages: [sentRow("drained-row", appMessageId: id)])
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.sendAttempts.first?.status == .accepted)
        #expect(store.sendAttempts.first?.confirmedMessageId == "drained-row")
        #expect(store.messages.map(\.id) == ["drained-row"])
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func malformedSendAcknowledgementIsUnconfirmed() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        try? await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w")
        #expect(store.lastFailedSend?.status == .unconfirmed)
        #expect(!store.isStreaming)
    }

    @Test func cancellingAfterDispatchRetainsUnconfirmedAttempt() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        let store = ConversationStore(connectionManager: fake)
        let send = Task { try? await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        send.cancel()
        await send.value
        #expect(store.lastFailedSend?.status == .unconfirmed)
        #expect(store.lastFailedSend?.canRetry == false)
        #expect(!store.isStreaming)
    }

    @Test(arguments: ["queued", "accepted", "timeout", "cancelled", "malformed"])
    func drainedTranscriptBeforeAnyQueueOrReplyWinsOverLateOutcome(outcome: String) async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        let send = Task { try await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        let id = try #require(store.sendAttempts.first?.id)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 1,
            snapshot: [sentRow("drained", appMessageId: id)],
            delta: nil
        ))
        #expect(store.queuedMessages.isEmpty)
        #expect(store.sendAttempts.first?.status == .accepted, "no queue entry or RPC reply has arrived")
        #expect(store.sendAttempts.first?.confirmedMessageId == "drained")
        switch outcome {
        case "queued":
            fake.resolvePending("agent.sendMessage", with: [
                "success": true, "queued": true, "queuedMessage": queuedSend("queue-1", originalId: id)
            ])
        case "accepted":
            fake.resolvePending("agent.sendMessage", with: ["success": true, "queued": false, "messageId": id])
        case "timeout": fake.failPending("agent.sendMessage", with: NSError(domain: "WebSocket", code: -2))
        case "cancelled": send.cancel()
        default: fake.resolvePending("agent.sendMessage", with: [:] as [String: Any])
        }
        try await send.value
        #expect(store.sendAttempts.first?.status == .accepted)
        #expect(store.sendAttempts.first?.confirmedMessageId == "drained")
        #expect(store.lastFailedSend == nil)
        #expect(store.messages.map(\.id) == ["drained"])
        #expect(store.messages.first?.appMessageId == id)
        #expect(store.queuedMessages.isEmpty)
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func topLevelTranscriptCorrelationWinsOverConflictingNestedMetadata() async throws {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2)
        let store = ConversationStore(connectionManager: fake)
        try? await store.sendMessage(agentId: "a", content: "first", workspaceId: "w")
        try? await store.sendMessage(agentId: "a", content: "second", workspaceId: "w")
        let first = try #require(store.sendAttempts.first?.id)
        let second = try #require(store.sendAttempts.last?.id)
        var row = sentRow("server-row", appMessageId: second)
        row["metadata"] = ["userAppMessageId": first]
        fake.stubChatSnapshot(messages: [row])
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.sendAttempts.first?.status == .unconfirmed)
        #expect(store.sendAttempts.last?.status == .accepted)
        #expect(store.sendAttempts.last?.confirmedMessageId == "server-row")
        #expect(fake.paramsForMethod("agent.sendMessage").count == 2)
    }

    @Test func resetIgnoresLateQueuedSendAcknowledgement() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        let store = ConversationStore(connectionManager: fake)
        let send = Task { try? await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        let id = try #require(store.sendAttempts.first?.id)
        store.reset()
        fake.resolvePending("agent.sendMessage", with: [
            "success": true, "queued": true, "queuedMessage": queuedSend("queue-1", originalId: id)
        ])
        await send.value
        #expect(store.sendAttempts.isEmpty)
        #expect(store.queuedMessages.isEmpty)
        #expect(store.messages.isEmpty)
        #expect(!store.isStreaming)
    }

    @Test func unrelatedDeltaCannotConfirmOptimisticRow() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.sendMessage")
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        let send = Task { try? await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 1,
            snapshot: nil,
            delta: .init(
                added: [
                    [
                        "messageId": "other-user", "role": "user",
                        "block": ["id": "other-user:0", "type": "text", "text": "other"]
                    ]
                ],
                updated: [],
                removedIds: []
            )
        ))
        #expect(store.sendAttempts.first?.status == .sending)
        fake.failPending("agent.sendMessage", with: NSError(domain: "WebSocket", code: -2))
        await send.value
        #expect(store.lastFailedSend?.status == .unconfirmed)
    }
}

extension ConversationStoreTests {
    /// Use the same decoded snapshot/event paths as ordinary transcript and queue updates.
    func deliverRecoveryRow(
        _ rowId: String,
        source: String,
        store: ConversationStore,
        fake: FakeConnectionManager,
        correlation: String? = nil,
        legacyId: String? = nil
    ) async {
        if source == "queue" {
            store.handleStreamEvent("events.event", params: [
                "event": [
                    "type": "agent:queue:updated",
                    "data": ["agentId": "a", "queue": [queuedSend(rowId, originalId: correlation)]]
                ]
            ])
        } else {
            var row = sentRow(rowId, appMessageId: source == "topLevel" ? correlation : nil)
            if let nestedId = source == "legacy" ? correlation : legacyId {
                row["metadata"] = ["userAppMessageId": nestedId]
            }
            fake.stubChatSnapshot(messages: [row])
            await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        }
    }

    @Test(arguments: ["topLevel", "legacy", "queue"], [false, true])
    func explicitRecoveryCorrelationExcludesConflictingIdentities(source: String, unknown: Bool) async throws {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2)
        let store = ConversationStore(connectionManager: fake)
        store.bindAgent("a")
        let stopped = Mutex<[URL]>([])
        for name in ["direct", "owner"] {
            let url = URL(fileURLWithPath: "/tmp/\(name).txt")
            let id = store.beginSendAttempt(
                agentId: "a",
                content: name,
                workspaceId: "w",
                files: [PendingFile(url: url, displayName: name, size: 0)],
                fileAccess: ConversationSendFileAccess(urls: [url]) { url in
                    stopped.withLock { $0.append(url) }
                }
            )
            store.prepareSendAttempt(id, imagePayload: .none, filePayload: .attachments([["type": "file", "attachmentId": name]]))
            try? await store.sendPreparedAttempt(id)
        }
        let direct = store.sendAttempts[0].id
        let owner = store.sendAttempts[1].id
        fake.errorMap.removeValue(forKey: "agent.sendMessage")
        fake.responseMap["agent.sendMessage"] = [
            "success": true, "queued": true, "queuedMessage": queuedSend(direct)
        ]
        try await store.sendMessage(agentId: "a", content: "prior", workspaceId: "w")
        await deliverRecoveryRow(
            direct,
            source: source,
            store: store,
            fake: fake,
            correlation: unknown ? "unknown" : owner,
            legacyId: unknown ? owner : direct
        )
        let confirmed: ConversationSendAttempt.Status = source == "queue" ? .queued : .accepted
        #expect(store.sendAttempts[0].status == .unconfirmed)
        #expect(store.sendAttempts[0].files.count == 1)
        #expect(store.sendAttempts[0].fileAccess != nil)
        #expect(store.sendAttempts[1].status == (unknown ? .unconfirmed : confirmed))
        #expect(store.sendAttempts[1].confirmedMessageId == (unknown ? nil : direct))
        #expect(store.sendAttempts[1].files.count == (unknown ? 1 : 0))
        #expect((store.sendAttempts[1].fileAccess != nil) == unknown)
        #expect(store.sendAttempts[2].status == .queued, "prior confirmed identity cannot override correlation")
        #expect(stopped.withLock { $0 } == (unknown ? [] : [URL(fileURLWithPath: "/tmp/owner.txt")]))
        var retainedPayload: [String: Any] = [:]
        store.sendAttempts[0].filePayload.apply(to: &retainedPayload)
        #expect((retainedPayload["fileBlocks"] as? [[String: Any]])?.first?["attachmentId"] as? String == "direct")
        #expect(fake.paramsForMethod("agent.sendMessage").count == 3, "reconciliation never replays a send")
    }

    @Test(arguments: ["topLevel", "legacy", "queue"], ["correlated", "direct", "prior"])
    func recoveryCorrelationKeepsBoundAgentFiltering(source: String, identity: String) async throws {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -2)
        let store = ConversationStore(connectionManager: fake)
        store.bindAgent("a")
        try? await store.sendMessage(agentId: "a", content: "bound", workspaceId: "w")
        let bound = try #require(store.sendAttempts.first?.id)
        if identity == "prior" {
            fake.errorMap.removeValue(forKey: "agent.sendMessage")
            fake.responseMap["agent.sendMessage"] = [
                "success": true, "queued": true, "queuedMessage": queuedSend(bound)
            ]
        }
        try? await store.sendMessage(agentId: "b", content: "other agent", workspaceId: "w")
        let other = try #require(store.sendAttempts.last?.id)
        await deliverRecoveryRow(
            identity == "direct" ? other : bound,
            source: source,
            store: store,
            fake: fake,
            correlation: identity == "correlated" ? other : nil
        )
        let expected: ConversationSendAttempt.Status = source == "queue" ? .queued : .accepted
        #expect(store.sendAttempts[0].status == (identity == "prior" ? expected : .unconfirmed))
        #expect(store.sendAttempts[1].status == (identity == "prior" ? .queued : .unconfirmed))
        #expect(fake.paramsForMethod("agent.sendMessage").count == 2)
    }

    @Test func localDisconnectedSendRetainsRetryAndRecordsOnlyOnce() async throws {
        let diagnostics = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: diagnostics)
        let store = ConversationStore(connectionManager: manager)
        let marker = "synthetic-private-send-content"
        do {
            try await store.sendMessage(agentId: "a", content: marker, workspaceId: "w")
            Issue.record("Expected pre-dispatch disconnection")
        } catch {
            let failure = DiagnosticErrorOwnership.failure(for: error)
            #expect(failure.origin == .localRequest)
            #expect(failure.classification == .notConnected)
            #expect(!DiagnosticErrorOwnership.record(error, event: DiagnosticFixtures.event(), store: diagnostics))
        }
        let attempt = try #require(store.lastFailedSend)
        #expect(attempt.status == .notSent)
        #expect(attempt.canRetry)
        #expect(attempt.content == marker)
        #expect(!store.isStreaming)
        let snapshot = await diagnostics.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.count == 1)
        #expect(records.first?.event.effect == .notSent)
        #expect(try #require(String(data: snapshot.jsonLines, encoding: .utf8)).contains(marker) == false)
    }

    @Test func remoteNotConnectedCodeCannotEnableReplayOrDuplicateDiagnostics() async throws {
        let diagnostics = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: diagnostics)
        let fake = FakeConnectionManager()
        do {
            _ = try await manager.awaitResponse(id: 1, timeout: 10) {
                manager.handleTextMessage("""
                {"id":1,"error":{"code":-4,"message":"synthetic-private-remote-error"}}
                """)
                return nil
            }
            Issue.record("Expected remote RPC error")
        } catch {
            fake.errorMap["agent.sendMessage"] = error
        }
        let remoteError = try #require(fake.errorMap["agent.sendMessage"])
        #expect(DiagnosticErrorOwnership.failure(for: remoteError).origin == .remoteRPC)
        let store = ConversationStore(connectionManager: fake)
        await #expect(throws: (any Error).self) {
            try await store.sendMessage(agentId: "a", content: "hello", workspaceId: "w")
        }
        let attempt = try #require(store.lastFailedSend)
        #expect(attempt.status == .unconfirmed)
        #expect(!attempt.canRetry)
        await #expect(throws: ConversationSendError.self) { try await store.sendPreparedAttempt(attempt.id) }
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
        #expect(!DiagnosticErrorOwnership.record(remoteError, event: DiagnosticFixtures.event(), store: diagnostics))
        let snapshot = await diagnostics.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.count == 1)
        #expect(records.first?.event.failure.origin == .remoteRPC)
        #expect(records.first?.event.effect == .remoteRejected)
        #expect(try #require(String(data: snapshot.jsonLines, encoding: .utf8)).contains("synthetic-private-remote-error") == false)
    }
}
