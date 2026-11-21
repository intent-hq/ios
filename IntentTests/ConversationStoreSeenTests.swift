import Foundation
@testable import Intent
import Testing

extension ConversationStoreTests {
    // MARK: - Seen marker (agent.markSeen, PROTOCOL §5.5)

    @Test func fetchAgentStreamingStateRestoresSeenMarkerFromMetadata() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a",
                "name": "Test",
                "metadata": ["lastSeenMessageId": "m1"]
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a")

        #expect(
            store.lastSeenMessageId == "m1",
            "the daemon-persisted seen marker must survive reload (AgentLite metadata)"
        )
    }

    @Test func fetchAgentStreamingStateRaiseOnlyStillAppliesSeenMarker() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a",
                "name": "Test",
                "metadata": ["lastSeenMessageId": "m1"]
            ] as [String: Any]
        ]
        let store = ConversationStore(connectionManager: fake)

        await store.fetchAgentStreamingState(agentId: "a", raiseOnly: true)

        #expect(
            store.lastSeenMessageId == "m1",
            "raiseOnly only gates isStreaming — the marker refresh applies on both paths"
        )
    }

    @Test func agentUpdatedEventAppliesSeenMarkerPushStyle() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

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
            store.lastSeenMessageId == "m9",
            "a marker move from another client must converge here push-style"
        )
    }

    @Test func agentUpdatedEventForOtherAgentDoesNotMoveSeenMarker() async {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:updated",
                "data": [
                    "agentId": "someone-else",
                    "lastSeenMessageId": "m9"
                ]
            ] as [String: Any]
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
            "success": true,
            "lastSeenMessageId": "m2"
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.messages = [
            ConversationMessage(id: "m1", role: .user),
            ConversationMessage(id: "m2", role: .assistant)
        ]

        await store.markSeen(agentId: "a", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.markSeen" })
        #expect(sent.params["agentId"] as? String == "a")
        #expect(sent.params["messageId"] as? String == "m2")
        #expect(sent.params["workspaceId"] as? String == "w")
        #expect(
            store.lastSeenMessageId == "m2",
            "the confirmed marker from the result is adopted"
        )
    }

    @Test func markSeenSkipsStreamingRows() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.markSeen"] = [
            "success": true,
            "lastSeenMessageId": "m1"
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)
        store.messages = [
            ConversationMessage(id: "m1", role: .user),
            ConversationMessage(id: "m2", role: .assistant, streamingState: .streaming)
        ]

        await store.markSeen(agentId: "a", workspaceId: "w")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.markSeen" })
        #expect(
            sent.params["messageId"] as? String == "m1",
            "streaming rows are never eligible — the marker must name a persisted message"
        )
    }

    @Test func markSeenNoopWithoutPersistedMessages() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.messages = [
            ConversationMessage(id: "m1", role: .assistant, streamingState: .streaming)
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

        #expect(
            fake.paramsForMethod("agent.markSeen").count == 1,
            "re-triggering the same target must not re-send"
        )
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
        fake.errorMap["agent.markSeen"] = NSError(domain: "WebSocket", code: -32_000)
        let store = ConversationStore(connectionManager: fake)
        store.messages = [ConversationMessage(id: "m1", role: .assistant)]

        await store.markSeen(agentId: "a", workspaceId: "w")
        #expect(store.lastSeenMessageId == nil, "a failed call must not move the marker")

        fake.errorMap.removeValue(forKey: "agent.markSeen")
        fake.responseMap["agent.markSeen"] = [
            "success": true,
            "lastSeenMessageId": "m1"
        ] as [String: Any]
        await store.markSeen(agentId: "a", workspaceId: "w")

        #expect(
            fake.paramsForMethod("agent.markSeen").count == 2,
            "the dedupe record is rolled back on failure so a later trigger retries"
        )
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
