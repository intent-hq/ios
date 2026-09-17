import Foundation
@testable import Intent
import Testing

extension ConversationStoreTests {
    @Test func staleAgentGetReplyFromPreviousAgentDoesNotLeakMarkersIntoSwitchedAgent() async throws {
        // Regression: the generation was bumped only on agent:updated, so an
        // agent.get for A that completed after the store started loading B
        // (no push in between) wrote A's pending/dismissed/seen markers into B.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        await store.fetchConversation(agentId: "b", workspaceId: "w")

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

        #expect(
            store.pendingQuestionsMessageId == nil,
            "A's pending marker must not land in B's conversation"
        )
        #expect(
            store.dismissedQuestionsMessageId == nil,
            "A's dismissal marker must not land in B's conversation"
        )
        #expect(
            store.lastSeenMessageId == nil,
            "A's seen marker must not land in B's conversation"
        )
        #expect(
            store.pendingQuestionRecovery == nil,
            "no recovery seek may be started for A's marker against B"
        )
    }

    @Test func staleAgentGetReplyAfterResetDoesNotRestoreMarkers() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        store.reset()

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

        #expect(store.pendingQuestionsMessageId == nil)
        #expect(store.dismissedQuestionsMessageId == nil)
        #expect(store.lastSeenMessageId == nil)
        #expect(store.pendingQuestionRecovery == nil)
    }

    @Test func agentGetReplyStillAppliesMarkersWhenConversationBindsSameAgentWhileInFlight() async throws {
        // View load issues fetchConversation and the raise-only agent.get
        // concurrently: binding the same agent from nil must not make the
        // reply look stale.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true) }
        try await Task.sleep(nanoseconds: 50_000_000)

        await store.fetchConversation(agentId: "a", workspaceId: "w")

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "metadata": [
                    "pendingQuestionsMessageId": "a1",
                    "lastSeenMessageId": "m3"
                ]
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.pendingQuestionsMessageId == "a1")
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
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "someone-else",
                    "pendingQuestionsMessageId": "x1"
                ]
            ] as [String: Any]
        ])

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "metadata": ["pendingQuestionsMessageId": "a1"]
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.pendingQuestionsMessageId == "a1")
    }

    @Test func staleAgentGetReplyFromPreviousAgentDoesNotTouchStreamingOrAttention() async throws {
        // Regression (PR #213 review): the agent-mismatch guard covered only
        // the markers, so an agent.get for A that completed after the store
        // switched to B still wrote A's isStreaming/attentionRequest into B.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        await store.fetchConversation(agentId: "b", workspaceId: "w")
        store.isStreaming = false
        store.attentionRequest = PendingAttentionRequest(kind: .discussion, reason: "b needs input")

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true,
                "attentionRequestKind": "blocker",
                "attentionRequestReason": "a is stuck"
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(
            !store.isStreaming,
            "A's streaming state must not land in B's conversation"
        )
        #expect(
            store.attentionRequest?.kind == .discussion,
            "A's attention request must not replace B's"
        )
        #expect(store.attentionRequest?.reason == "b needs input")
    }

    @Test func staleRaiseOnlyAgentGetReplyFromPreviousAgentDoesNotRaiseStreaming() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true) }
        try await Task.sleep(nanoseconds: 50_000_000)

        await store.fetchConversation(agentId: "b", workspaceId: "w")
        store.isStreaming = false
        store.attentionRequest = nil

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true,
                "attentionRequestKind": "blocker"
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(!store.isStreaming, "raiseOnly must not raise B's streaming flag from A's reply")
        #expect(store.attentionRequest == nil, "A's attention request must not be raised on B")
    }

    @Test func staleNotFoundForPreviousAgentDoesNotMarkSwitchedAgentDeleted() async throws {
        // A definitive not-found for A arriving after the store switched to B
        // says nothing about B.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.delayMap["agent.get"] = 150_000_000
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: a",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        await store.fetchConversation(agentId: "b", workspaceId: "w")
        await refresh.value

        #expect(
            !store.agentNotFound,
            "a not-found for the previous agent must not mark the current one deleted"
        )
    }
}

extension ConversationStoreTests {
    @Test func staleAgentGetReplyAfterResetDoesNotRestoreStreamingOrAttention() async throws {
        // Regression (PR #215 review): reset() unbinds the store, and an
        // unbound store used to accept any reply — so an agent.get issued
        // while bound to A restored A's isStreaming/attentionRequest into the
        // store reset() had just cleared.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        store.reset()

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true,
                "attentionRequestKind": "blocker",
                "attentionRequestReason": "a is stuck"
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(!store.isStreaming, "a stale reply must not restore streaming state after reset")
        #expect(store.attentionRequest == nil, "a stale reply must not restore the attention request after reset")
    }

    @Test func staleNotFoundAfterResetDoesNotRaiseAgentNotFound() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.delayMap["agent.get"] = 150_000_000
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: a",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        store.reset()
        await refresh.value

        #expect(
            !store.agentNotFound,
            "a stale not-found must not mark the reset store as deleted"
        )
    }

    @Test func agentGetReplyAfterMarkerPushStillAppliesStreamingAndAttention() async throws {
        // Pins the split: a generation bump without an agent change (an
        // agent:updated push for the same agent) skips only the markers —
        // streaming/attention state is not carried by the push and must still
        // be taken from the reply.
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        store.attentionRequest = PendingAttentionRequest(kind: .discussion, reason: "stale")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await Task.sleep(nanoseconds: 50_000_000)

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "pendingQuestionsMessageId": "a2"
                ]
            ] as [String: Any]
        ])

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true,
                "attentionRequestKind": "blocker",
                "attentionRequestReason": "sandbox is broken",
                "metadata": [
                    "pendingQuestionsMessageId": "a1",
                    "lastSeenMessageId": "m3"
                ]
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.isStreaming, "streaming state is applied despite the marker push")
        #expect(
            store.attentionRequest?.kind == .blocker,
            "attention state is applied despite the marker push"
        )
        #expect(
            store.pendingQuestionsMessageId == "a2",
            "the pushed marker wins over the stale reply"
        )
        #expect(
            store.lastSeenMessageId == nil,
            "the stale reply's seen marker is skipped"
        )
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
                "id": "a",
                "name": "A",
                "metadata": ["pendingQuestionsMessageId": "a1"]
            ] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        let fetch = Task { await store.fetchConversation(agentId: "a", workspaceId: "w") }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:status-changed",
                "data": ["agentId": "a", "status": "idle"]
            ] as [String: Any]
        ])
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:idle", "data": ["agentId": "a"]] as [String: Any]
        ])
        #expect(
            store.pendingQuestionsMessageId == nil,
            "turn boundaries are buffered while the fetch is in flight"
        )

        fake.resolvePending("agent.getConversation", with: ["messages": []] as [String: Any])
        await fetch.value
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!store.isLoading)
        #expect(
            store.pendingQuestionsMessageId == "a1",
            "the buffered turn boundary still refreshes the marker after load"
        )
        #expect(
            fake.requestLog.filter { $0.method == "agent.get" }.count == 1,
            "one refresh regardless of how many boundaries were buffered"
        )
    }

    @Test func agentUpdatedEventWithoutPendingMarkerLeavesItUntouched() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        store.pendingQuestionsMessageId = "a1"

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "a",
                    "lastSeenMessageId": "m9"
                ]
            ] as [String: Any]
        ])

        #expect(store.pendingQuestionsMessageId == "a1")
    }

    @Test func agentUpdatedEventForOtherAgentDoesNotMovePendingMarker() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "someone-else",
                    "pendingQuestionsMessageId": "x1"
                ]
            ] as [String: Any]
        ])

        #expect(store.pendingQuestionsMessageId == nil)
    }

    @Test func resetClearsPendingMarker() {
        let store = ConversationStore()
        store.pendingQuestionsMessageId = "a1"
        store.reset()
        #expect(store.pendingQuestionsMessageId == nil)
    }
}
