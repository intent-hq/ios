import Foundation
@testable import Intent
import Testing

extension ConversationStoreTests {
    // MARK: - Marked question recovery (aroundMessageId seek, Phase 2)

    /// A question-bearing assistant row as the daemon serves it.
    private func questionRow(id: String) -> [String: Any] {
        [
            "id": id,
            "role": "assistant",
            "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": "Which one?"]]
        ]
    }

    private func pushMarker(_ store: ConversationStore, _ markerId: String) {
        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "pendingQuestionsMessageId": markerId
                ]
            ] as [String: Any]
        ])
    }

    private func seekRequests(_ fake: FakeConnectionManager) -> [[String: Any]] {
        fake.paramsForMethod("agent.getConversation").filter { $0["aroundMessageId"] != nil }
    }

    @Test func markerNamingMissingRowIssuesOneAroundMessageIdSeek() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.responseMap["agent.getConversation"] = ["messages": [questionRow(id: "q1")]] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.pendingQuestionRecovery == nil)

        pushMarker(store, "q1")
        #expect(
            store.pendingQuestionRecovery?.status == .loading,
            "fails closed while the seek is in flight"
        )
        try await waitUntil("the seek to settle") { store.pendingQuestionRecovery?.status != .loading }

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
        try await expectNever("re-seek for the same marker") { seekRequests(fake).count > 1 }
    }

    @Test func markerNamingResidentRowIssuesNoSeek() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot(messages: [questionRow(id: "q1")])
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        pushMarker(store, "q1")
        try await expectNever("seek for a resident row") { !seekRequests(fake).isEmpty }
        #expect(store.pendingQuestionRecovery == nil)
    }

    @Test func seekPageWithoutTheRowSettlesNotFound() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        pushMarker(store, "q1")
        try await waitUntil("the seek to settle") { store.pendingQuestionRecovery?.status != .loading }

        #expect(store.pendingQuestionRecovery?.status == .notFound)
        #expect(store.pendingQuestionRecovery?.message == nil)
    }

    @Test func seekUnknownMessageId32602SettlesNotFoundWithoutRetry() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        // PROTOCOL §5.5: an unknown aroundMessageId is -32602 naming the id
        // (no data.code == "not-found" — the agent itself exists).
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "unknown message id: q1"]
        )
        // Shorter than the observation window below, so a retry wrongly scheduled
        // after the terminal error would fire inside it (default delay is 250 ms).
        store.markedQuestionRetryDelays = [.milliseconds(10), .milliseconds(10)]

        pushMarker(store, "q1")
        try await waitUntil("the seek to settle") { store.pendingQuestionRecovery?.status != .loading }
        try await expectNever("retry after -32602 (terminal)") { seekRequests(fake).count > 1 }
        #expect(store.pendingQuestionRecovery?.status == .notFound)
        #expect(!store.agentNotFound, "an unknown message id is not a deleted agent")
    }

    @Test func seekTransportErrorRetriesThenSettlesFound() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.errorQueueMap["agent.getConversation"] = [
            NSError(
                domain: "WebSocket",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
            )
        ]
        fake.responseMap["agent.getConversation"] = ["messages": [questionRow(id: "q1")]] as [String: Any]

        pushMarker(store, "q1")
        try await fake.waitForRequests("agent.getConversation", count: 1)
        #expect(seekRequests(fake).count == 1)
        #expect(
            store.pendingQuestionRecovery?.status == .loading,
            "still loading while waiting for the 250 ms retry"
        )

        try await waitUntil("the retried seek to settle") { store.pendingQuestionRecovery?.status != .loading }
        #expect(seekRequests(fake).count == 2, "one retry after the transport error")
        #expect(store.pendingQuestionRecovery?.status == .found)
        #expect(store.pendingQuestionRecovery?.message?.id == "q1")
    }

    @Test func seekExhaustedRetriesSettlesError() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.errorMap["agent.getConversation"] = NSError(
            domain: "WebSocket",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )
        store.markedQuestionRetryDelays = [.milliseconds(10), .milliseconds(10)]

        pushMarker(store, "q1")
        try await waitUntil("the retries to exhaust") { store.pendingQuestionRecovery?.status != .loading }

        #expect(seekRequests(fake).count == 3, "initial attempt + two retries")
        #expect(store.pendingQuestionRecovery?.status == .error)
    }

    @Test func markerClearedMidFlightCancelsSeekAndDropsState() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(seekRequests(fake).count == 1)
        #expect(store.pendingQuestionRecovery?.status == .loading)

        pushMarker(store, "")
        #expect(store.pendingQuestionRecovery == nil, "the marker clear drops the state")

        fake.resolvePending(
            "agent.getConversation",
            with: ["messages": [questionRow(id: "q1")]] as [String: Any]
        )
        try await expectNever("late reply for the cancelled seek settling state") {
            store.pendingQuestionRecovery != nil
        }
    }

    @Test func markerReplacedMidFlightRestartsSeekForTheNewId() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await fake.waitForRequests("agent.getConversation", count: 1)
        pushMarker(store, "q2")
        try await fake.waitForRequests("agent.getConversation", count: 2)

        let seeks = seekRequests(fake)
        #expect(seeks.map { $0["aroundMessageId"] as? String } == ["q1", "q2"])
        #expect(store.pendingQuestionRecovery?.messageId == "q2")
        #expect(store.pendingQuestionRecovery?.status == .loading)
    }

    @Test func rowArrivingInTranscriptWhileSeekInFlightSettlesFoundFromResidentRow() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot(subscriptionId: "sub-chat")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(store.pendingQuestionRecovery?.status == .loading)

        store.handleStreamEvent("subscription.push", params: [
            "subscriptionId": "sub-chat",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": ["agentId": "a", "messages": [questionRow(id: "q1")]] as [String: Any]
        ] as [String: Any])

        #expect(store.messages.map(\.id) == ["q1"])
        #expect(
            store.pendingQuestionRecovery?.status == .found,
            "the resident row settles the in-flight seek"
        )
        #expect(store.pendingQuestionRecovery?.message?.id == "q1")
    }
}

extension ConversationStoreTests {
    @Test func liveChatSnapshotThroughRegisteredHandlerSettlesInFlightSeek() async throws {
        // Production path: chat.subscribe registers the push handler with the
        // connection manager, and the snapshot arrives through that handler
        // (not through handleStreamEvent).
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot(subscriptionId: "sub-chat")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(store.pendingQuestionRecovery?.status == .loading)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-chat",
            seq: 0,
            conversationSnapshot: [questionRow(id: "q1")],
            metadata: ["agentId": "a"]
        ))

        #expect(store.messages.map(\.id) == ["q1"])
        #expect(
            store.pendingQuestionRecovery?.status == .found,
            "the live-channel snapshot settles the in-flight seek from the resident row"
        )
        #expect(store.pendingQuestionRecovery?.message?.id == "q1")
    }

    @Test func liveChatDeltaThroughRegisteredHandlerSettlesInFlightSeek() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot(subscriptionId: "sub-chat")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")

        pushMarker(store, "q1")
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(store.pendingQuestionRecovery?.status == .loading)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-chat",
            seq: 1,
            delta: .init(
                added: [
                    [
                        "messageId": "q1",
                        "role": "assistant",
                        "timestamp": "2024-01-01T00:00:00Z",
                        "streamingComplete": true,
                        "block": ["id": "q1:0", "type": "text", "text": "Which one?"] as [String: Any]
                    ] as [String: Any]
                ],
                updated: [],
                removedIds: []
            )
        ))

        #expect(store.messages.map(\.id) == ["q1"])
        #expect(
            store.pendingQuestionRecovery?.status == .found,
            "a live-channel delta that materialises the row settles the in-flight seek"
        )
        #expect(store.pendingQuestionRecovery?.message?.id == "q1")
    }

    @Test func markerPushedDuringInitialLoadSeeksOnceTheSnapshotLands() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat"]
        let store = ConversationStore(connectionManager: fake)

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.isLoading)

        pushMarker(store, "q1")
        #expect(store.pendingQuestionRecovery == nil, "no seek while the seq-0 snapshot is pending")

        fake.responseMap["agent.getConversation"] = ["messages": [questionRow(id: "q1")]] as [String: Any]
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-chat",
            seq: 0,
            conversationSnapshot: [],
            metadata: ["agentId": "a"]
        ))
        #expect(!store.isLoading)
        try await waitUntil("the deferred seek to settle") { store.pendingQuestionRecovery?.status == .found }

        #expect(seekRequests(fake).count == 1)
        #expect(store.pendingQuestionRecovery?.status == .found)
    }

    @Test func resetClearsPendingQuestionRecovery() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")
        pushMarker(store, "q1")
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(store.pendingQuestionRecovery != nil)

        store.reset()

        #expect(store.pendingQuestionRecovery == nil)
    }

    @Test func agentDeletedEventDropsPendingQuestionRecovery() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.pendingMethods.insert("agent.getConversation")
        pushMarker(store, "q1")
        try await fake.waitForPendingRequests("agent.getConversation")
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
            agentId: "a",
            content: "Q: x\nA: y",
            workspaceId: "w",
            messageMetadata: .fields([
                "type": "question_answers",
                "answeredQuestionsMessageId": "msg-q1"
            ])
        )

        let row = try #require(store.messages.last)
        #expect(row.role == .user)
        #expect(row.metadata["type"]?.stringValue == "question_answers")
        #expect(row.answeredQuestionsMessageId == "msg-q1")
    }

    @Test func sendMessageLeavesOptimisticRowMetadataNilWhenAbsent() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.sendMessage(agentId: "a", content: "hi", workspaceId: "w")

        let row = try #require(store.messages.last)
        #expect(row.metadata.isEmpty)
        #expect(!row.hasReportedMetadata)
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
            "success": true,
            "queued": true,
            "queuedMessage": [
                "id": "q-1",
                "content": "Q: x\nA: y",
                "queuedAt": "2026-01-01T00:00:00Z",
                "position": 0,
                "messageMetadata": [
                    "type": "question_answers",
                    "answeredQuestionsMessageId": "msg-q1"
                ]
            ] as [String: Any]
        ] as [String: Any]
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

        #expect(store.messages.isEmpty, "the optimistic row moves to the queue panel")
        #expect(store.queuedMessages.map(\.id) == ["q-1"])
        #expect(store.queuedMessages.first?.answeredQuestionsMessageId == "msg-q1")

        // An agent:queue:updated that raced ahead of the result is not duplicated.
        try await store.sendMessage(
            agentId: "a",
            content: "Q: x\nA: y",
            workspaceId: "w",
            messageMetadata: .fields([
                "type": "question_answers",
                "answeredQuestionsMessageId": "msg-q1"
            ])
        )
        #expect(store.queuedMessages.count == 1)
    }

    @Test func rollbackFailedSendRemovesTaggedOptimisticRow() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32_000)
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.sendMessage(
                agentId: "a",
                content: "Q: x\nA: y",
                workspaceId: "w",
                messageMetadata: .fields([
                    "type": "question_answers",
                    "answeredQuestionsMessageId": "msg-q1"
                ])
            )
        }
        #expect(store.messages.last?.answeredQuestionsMessageId == "msg-q1")

        store.rollbackFailedSend()

        #expect(store.messages.isEmpty, "the tagged row is removed so the set re-pends")
    }
}
