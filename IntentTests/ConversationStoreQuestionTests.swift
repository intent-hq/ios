import Foundation
@testable import Intent
import Testing

extension ConversationStoreTests {
    @Test func staleAgentGetReplyFromPreviousAgentDoesNotLeakMarkersIntoSwitchedAgent() async throws {
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

    @Test(arguments: [false, true])
    func agentGetReplyAfterMarkerPushPreservesChatStreamingAuthority(seenChanged: Bool) async throws {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        let refresh = Task { await store.fetchAgentStreamingState(agentId: "a") }
        try await fake.waitForPendingRequests("agent.get")

        var pushedMarkers = ["agentId": "a", "pendingQuestionsMessageId": "a2"]
        if seenChanged { pushedMarkers["lastSeenMessageId"] = "m4" }
        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": pushedMarkers
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

        #expect(!store.isStreaming, "the idle chat snapshot remains authoritative")
        #expect(
            store.pendingQuestionsMessageId == "a2",
            "the pushed marker wins over the stale reply"
        )
        #expect(
            store.lastSeenMessageId == (seenChanged ? "m4" : "m3"),
            "a newer seen event wins; an unrelated question marker does not erase entry read state"
        )
    }

    @Test func agentGetReplyBeforeChatSnapshotAppliesStreaming() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": ["id": "a", "isStreaming": true, "metadata": ["pendingQuestionsMessageId": "a1"]]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.bindAgent("a")

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(store.isStreaming, "agent detail supplies liveness before chat becomes authoritative")
        #expect(store.pendingQuestionsMessageId == "a1")
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
