import Foundation
@testable import Intent
import Testing

extension ConversationStoreTests {
    @Test func dismissQuestionsFallsBackToRequestedIdWhenResultOmitsMarker() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.dismissQuestions"] = ["success": true] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        try await store.dismissQuestions(agentId: "a", messageId: "a1", workspaceId: "w")

        #expect(store.dismissedQuestionsMessageId == "a1")
    }

    @Test func failedDismissRollsBackMarkerAndRethrows() async {
        let fake = FakeConnectionManager()
        fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32_000)
        let store = ConversationStore(connectionManager: fake)

        await #expect(throws: (any Error).self) {
            try await store.dismissQuestions(agentId: "a", messageId: "a1", workspaceId: "w")
        }

        #expect(
            store.dismissedQuestionsMessageId == nil,
            "a failed dismiss must roll the optimistic marker back so the wizard re-pends"
        )
    }

    @Test func dismissQuestionsRaisesMarkerOptimisticallyBeforeRpcReturns() async throws {
        // PR #86 review: the marker must be raised BEFORE the RPC resolves so
        // the wizard unmounts immediately — no in-flight window where a Send
        // or second Dismiss can race the same question message.
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.dismissQuestions")
        let store = ConversationStore(connectionManager: fake)

        let inFlight = Task { try await store.dismissQuestions(
            agentId: "a",
            messageId: "a1",
            workspaceId: "w"
        )
        }
        try await fake.waitForPendingRequests("agent.dismissQuestions")

        #expect(
            store.dismissedQuestionsMessageId == "a1",
            "the marker is raised optimistically while the RPC is in flight"
        )
        fake.resolvePending("agent.dismissQuestions", with: ["success": true] as [String: Any])
        try await inFlight.value
        #expect(store.dismissedQuestionsMessageId == "a1")
    }

    @Test func failedDismissRollbackPreservesConcurrentMarkerUpdate() async throws {
        // If another client's dismissal lands (agent:updated push) while our
        // failing RPC is in flight, the rollback must not clobber it.
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.dismissQuestions")
        let store = ConversationStore(connectionManager: fake)

        let inFlight = Task { try await store.dismissQuestions(
            agentId: "a",
            messageId: "a1",
            workspaceId: "w"
        )
        }
        try await fake.waitForPendingRequests("agent.dismissQuestions")
        store.dismissedQuestionsMessageId = "a2"

        fake.failPending("agent.dismissQuestions", with: NSError(domain: "WebSocket", code: -32_000))
        await #expect(throws: (any Error).self) { try await inFlight.value }
        #expect(
            store.dismissedQuestionsMessageId == "a2",
            "rollback must not clobber a marker moved while the RPC was in flight"
        )
    }

    @Test func agentUpdatedEventAppliesDismissalMarkerPushStyle() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "dismissedQuestionsMessageId": "a1"
                ]
            ] as [String: Any]
        ])

        #expect(
            store.dismissedQuestionsMessageId == "a1",
            "a dismissal from another client must retire the wizard here too"
        )
    }

    @Test func agentUpdatedEventForOtherAgentIsIgnored() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "someone-else",
                    "dismissedQuestionsMessageId": "x1"
                ]
            ] as [String: Any]
        ])

        #expect(store.dismissedQuestionsMessageId == nil)
    }

    @Test func agentUpdatedEventWithoutMarkerLeavesStateUntouched() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        store.dismissedQuestionsMessageId = "a1"

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "lastSeenMessageId": "m9"
                ]
            ] as [String: Any]
        ])

        #expect(
            store.dismissedQuestionsMessageId == "a1",
            "an unrelated agent:updated must not clear the marker"
        )
    }

    @Test func fetchAgentStreamingStateRestoresDismissalMarkerFromMetadata() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a",
                "name": "Test",
                "metadata": ["dismissedQuestionsMessageId": "a1"]
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(
            store.dismissedQuestionsMessageId == "a1",
            "the daemon-persisted marker must survive reload (AgentLite metadata)"
        )
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
                "id": "a",
                "name": "Test",
                "metadata": ["pendingQuestionsMessageId": "a1"]
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
                "id": "a",
                "name": "Test",
                "isStreaming": false,
                "metadata": ["pendingQuestionsMessageId": "a1"]
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
                "id": "a",
                "name": "Test",
                "metadata": ["pendingQuestionsMessageId": ""]
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)
        store.pendingQuestionsMessageId = "a1"

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.pendingQuestionsMessageId?.isEmpty == true)
    }

    @Test func fetchAgentStreamingStateWithoutPendingMarkerLeavesItUntouched() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a",
                "name": "Test",
                "metadata": ["dismissedQuestionsMessageId": "a0"]
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)
        store.pendingQuestionsMessageId = "a1"

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(
            store.pendingQuestionsMessageId == "a1",
            "an absent field is not a clear — only \"\" is"
        )
    }
}

extension ConversationStoreTests {
    @Test func agentUpdatedEventAppliesPendingMarkerPushStyle() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "pendingQuestionsMessageId": "a1"
                ]
            ] as [String: Any]
        ])
        #expect(store.pendingQuestionsMessageId == "a1")

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "pendingQuestionsMessageId": ""
                ]
            ] as [String: Any]
        ])
        #expect(
            store.pendingQuestionsMessageId?.isEmpty == true,
            "the daemon clearing the marker to \"\" must land push-style"
        )
    }

    @Test func agentUpdatedEventDuringInitialLoadIsAppliedNotDropped() async {
        // Regression (PR #210 review): the isLoading buffer only replays
        // user-message/stream events, so a marker clear pushed while the
        // initial chat.subscribe snapshot was pending used to be dropped —
        // the wizard then re-pended on the stale agent.get marker. Session
        // metadata pushes bypass the buffer and land immediately.
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        let store = ConversationStore(connectionManager: fake)
        store.pendingQuestionsMessageId = "a1"

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "pendingQuestionsMessageId": "",
                    "lastSeenMessageId": "m9"
                ]
            ] as [String: Any]
        ])
        #expect(
            store.pendingQuestionsMessageId?.isEmpty == true,
            "the marker clear lands while the fetch is still in flight"
        )
        #expect(store.lastSeenMessageId == "m9")

        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", seq: 0, snapshot: []))

        #expect(!store.isLoading)
        #expect(
            store.pendingQuestionsMessageId?.isEmpty == true,
            "settling the snapshot does not revert the pushed marker"
        )
        #expect(store.lastSeenMessageId == "m9")
    }

    @Test func staleAgentGetReplyDoesNotOverwriteMarkersPushedWhileInFlight() async throws {
        // Regression: an agent.get reply applied unconditionally used to
        // revert a marker that an agent:updated push moved after the request
        // started (e.g. a newer question-bearing turn's marker replaced by the
        // previous marker the daemon captured before it).
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "pendingQuestionsMessageId": "a2",
                    "dismissedQuestionsMessageId": "a1",
                    "lastSeenMessageId": "m9"
                ]
            ] as [String: Any]
        ])

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true,
                "metadata": [
                    "pendingQuestionsMessageId": "a1",
                    "dismissedQuestionsMessageId": "a0",
                    "lastSeenMessageId": "m3"
                ]
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(
            store.pendingQuestionsMessageId == "a2",
            "the stale reply must not revert the pushed pending marker"
        )
        #expect(
            store.dismissedQuestionsMessageId == "a1",
            "the stale reply must not revert the pushed dismissal marker"
        )
        #expect(
            store.lastSeenMessageId == "m9",
            "the stale reply must not revert the pushed seen marker"
        )
        #expect(
            store.isStreaming,
            "streaming state is still applied from the reply"
        )
    }

    @Test func agentGetReplyStillAppliesMarkersWhenNoPushIntervened() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "metadata": [
                    "pendingQuestionsMessageId": "a1",
                    "dismissedQuestionsMessageId": "a0",
                    "lastSeenMessageId": "m3"
                ]
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.pendingQuestionsMessageId == "a1")
        #expect(store.dismissedQuestionsMessageId == "a0")
        #expect(store.lastSeenMessageId == "m3")
    }
}
