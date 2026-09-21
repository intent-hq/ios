import Foundation
@testable import Intent
import Testing

extension ConversationStoreTests {
    @Test func staleAgentGetReplyFromPreviousAgentDoesNotLeakMarkersIntoSwitchedAgent() async throws {
        // Regression: the generation was bumped only on agent:updated, so an
        // agent.get for A that completed after the store started loading B
        // (no push in between) wrote A's pending/dismissed/seen markers into B.
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        await store.subscribeLiveChat(agentId: "b", workspaceId: "w")

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
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

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
        // View load issues subscribeLiveChat and the raise-only agent.get
        // concurrently: binding the same agent from nil must not make the
        // reply look stale.
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true) }
        try await fake.waitForPendingRequests("agent.get")

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

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

    @Test func staleAgentGetReplyFromPreviousAgentDoesNotTouchStreaming() async throws {
        // Regression (PR #213 review): the agent-mismatch guard covered only
        // the markers, so an agent.get for A that completed after the store
        // switched to B still wrote A's isStreaming into B.
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        await store.subscribeLiveChat(agentId: "b", workspaceId: "w")
        store.isStreaming = false

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(
            !store.isStreaming,
            "A's streaming state must not land in B's conversation"
        )
    }

    @Test func staleRaiseOnlyAgentGetReplyFromPreviousAgentDoesNotRaiseStreaming() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true) }
        try await fake.waitForPendingRequests("agent.get")

        await store.subscribeLiveChat(agentId: "b", workspaceId: "w")
        store.isStreaming = false

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(!store.isStreaming, "raiseOnly must not raise B's streaming flag from A's reply")
    }

    @Test func staleNotFoundForPreviousAgentDoesNotMarkSwitchedAgentDeleted() async throws {
        // A definitive not-found for A arriving after the store switched to B
        // says nothing about B.
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let notFound = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: a",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        await store.subscribeLiveChat(agentId: "b", workspaceId: "w")
        fake.failPending("agent.get", with: notFound)
        await refresh.value

        #expect(
            !store.agentNotFound,
            "a not-found for the previous agent must not mark the current one deleted"
        )
    }
}

extension ConversationStoreTests {
    @Test func staleAgentGetReplyAfterResetDoesNotRestoreStreaming() async throws {
        // Regression (PR #215 review): reset() unbinds the store, and an
        // unbound store used to accept any reply — so an agent.get issued
        // while bound to A restored A's isStreaming into the reset store.
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        store.reset()

        fake.resolvePending("agent.get", with: [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(!store.isStreaming, "a stale reply must not restore streaming state after reset")
    }

    @Test func staleNotFoundAfterResetDoesNotRaiseAgentNotFound() async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let notFound = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: a",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        store.reset()
        fake.failPending("agent.get", with: notFound)
        await refresh.value

        #expect(
            !store.agentNotFound,
            "a stale not-found must not mark the reset store as deleted"
        )
    }

    @Test func agentGetReplyAfterMarkerPushStillAppliesStreaming() async throws {
        // Pins the split: a generation bump without an agent change (an
        // agent:updated push for the same agent) skips only the markers —
        // streaming state is not carried by the push and must still be taken
        // from the reply.
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
                    "pendingQuestionsMessageId": "a2"
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
                    "lastSeenMessageId": "m3"
                ]
            ] as [String: Any]
        ] as [String: Any])
        await refresh.value

        #expect(store.isStreaming, "streaming state is applied despite the marker push")
        #expect(
            store.pendingQuestionsMessageId == "a2",
            "the pushed marker wins over the stale reply"
        )
        #expect(
            store.lastSeenMessageId == nil,
            "the stale reply's seen marker is skipped"
        )
    }

    @Test func turnBoundaryDuringInitialLoadRefreshesTheMarkerWithoutReplay() async throws {
        // Regression (PR #210 review): a turn ending mid-load must still raise
        // the pending-questions marker. There is no stream-event buffer any
        // more: agent:idle / agent:status-changed refresh the marker as they
        // land, one raiseOnly agent.get each, and the seq-0 snapshot neither
        // replays them nor issues a refresh of its own.
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat"]
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a",
                "name": "A",
                "metadata": ["pendingQuestionsMessageId": "a1"]
            ] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
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
        try await waitUntil("the mid-load turn boundaries to refresh the marker") {
            store.pendingQuestionsMessageId == "a1"
        }
        try await waitUntil("one agent.get per turn boundary") {
            fake.requestLog.filter { $0.method == "agent.get" }.count == 2
        }
        #expect(store.isLoading, "the marker refresh does not finish the initial load")

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-chat",
            seq: 0,
            conversationSnapshot: [],
            metadata: ["agentId": "a"]
        ))
        #expect(!store.isLoading)
        // The snapshot is the transcript; it neither replays the boundaries
        // nor adds a refresh of its own.
        try await expectNever("an agent.get issued by the snapshot") {
            fake.requestLog.filter { $0.method == "agent.get" }.count > 2
        }
        #expect(
            store.pendingQuestionsMessageId == "a1",
            "the marker raised mid-load survives the snapshot"
        )
    }

    @Test func agentUpdatedEventWithoutPendingMarkerLeavesItUntouched() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
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
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

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
