import Foundation
@testable import Intent
import Testing

/// Retention bound on `streamEventBuffer` while the initial
/// `agent.getConversation` is in flight (ios#380): a burst under budget
/// replays in order; a burst over budget is not retained and the store
/// reconciles from the daemon instead of replaying a lossy buffer.
@MainActor
struct ConversationStoreStreamEventBufferTests {
    private static let countBurstSize = 600
    private static let largePayloadBytes = 1 << 20
    private static let largePayloadBurstSize = 3

    private func makeLoadingStore(
        chatLive: Bool = false
    ) async throws -> (ConversationStore, FakeConnectionManager, Task<Void, Never>) {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.getConversation")
        fake.responseMap["agent.get"] = ["agent": ["id": "a", "isStreaming": false] as [String: Any]]
        let store = ConversationStore(connectionManager: fake)
        if chatLive { seedLiveChatChannel(store) }
        let fetch = Task { await store.fetchConversation(agentId: "a", workspaceId: "w") }
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(store.isLoading)
        return (store, fake, fetch)
    }

    /// `chatLive` only flips once a seq-0 snapshot is applied (PROTOCOL §7.1);
    /// activating the channel alone leaves the store on the legacy path.
    private func seedLiveChatChannel(_ store: ConversationStore) {
        store.setTestChatChannel(subscriptionId: "sub-chat-123")
        store.handleStreamEvent("subscription.push", params: [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": ["agentId": "a", "messages": [] as [[String: Any]]] as [String: Any]
        ] as [String: Any])
        #expect(!store.liveTranscript.shouldRefetchAfterLegacyStreamEnd)
    }

    private func pushUserMessage(_ store: ConversationStore, id: String, content: String = "hi") {
        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:user-message:sent",
                "data": ["agentId": "a", "messageId": id, "content": content]
            ] as [String: Any]
        ])
    }

    private func pushStreamEvent(_ store: ConversationStore, type: String, extra: [String: Any] = [:]) {
        var data: [String: Any] = ["agentId": "a"]
        for (key, value) in extra { data[key] = value }
        store.handleStreamEvent("events.event", params: [
            "event": ["type": type, "data": data] as [String: Any]
        ])
    }

    private func userRow(id: String) -> [String: Any] {
        [
            "id": id,
            "role": "user",
            "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": "hi"]]
        ]
    }

    private func settleInitialFetch(
        _ fake: FakeConnectionManager,
        _ fetch: Task<Void, Never>,
        page: [[String: Any]] = []
    ) async {
        fake.pendingMethods.remove("agent.getConversation")
        fake.resolvePending("agent.getConversation", with: ["messages": page] as [String: Any])
        await fetch.value
    }

    // MARK: - Under budget

    @Test func burstUnderBudgetReplaysInOrder() async throws {
        let (store, fake, fetch) = try await makeLoadingStore()
        let ids = (1...8).map { "m\($0)" }
        pushStreamEvent(store, type: "agent:stream:start", extra: ["streamId": "s1"])
        for id in ids { pushUserMessage(store, id: id) }
        #expect(store.streamEventBuffer.count == ids.count + 1)

        await settleInitialFetch(fake, fetch)

        #expect(!store.isLoading)
        #expect(store.streamEventBuffer.isEmpty, "the buffer is released once the load settles")
        #expect(store.messages.map(\.id) == ids, "buffered user messages replay in arrival order")
        #expect(store.isStreaming)
        #expect(store.currentStreamId == "s1")
        try await expectNever("a recovery fetch for an under-budget burst") {
            fake.paramsForMethod("agent.getConversation").count > 1 || !fake.paramsForMethod("agent.get").isEmpty
        }
    }

    // MARK: - Over budget

    @Test func burstOverCountBudgetIsBoundedAndReconcilesFromTheDaemon() async throws {
        let (store, fake, fetch) = try await makeLoadingStore()
        for index in 1...Self.countBurstSize { pushUserMessage(store, id: "m\(index)") }
        #expect(
            store.streamEventBuffer.count < Self.countBurstSize,
            "retention while loading must be bounded, not proportional to the burst"
        )

        fake.responseMap["agent.getConversation"] = ["messages": [userRow(id: "r1"), userRow(id: "r2")]]
        await settleInitialFetch(fake, fetch)

        #expect(store.streamEventBuffer.isEmpty)
        try await waitUntil("the authoritative state fetch") { fake.paramsForMethod("agent.get").count == 1 }
        try await waitUntil("the recovery refetch to land") { store.messages.map(\.id) == ["r1", "r2"] }
        #expect(fake.paramsForMethod("agent.getConversation").count == 2, "overflow forces one full refetch")
    }

    @Test func burstOverByteBudgetIsBoundedAndReconcilesFromTheDaemon() async throws {
        let (store, fake, fetch) = try await makeLoadingStore()
        let payload = String(repeating: "x", count: Self.largePayloadBytes)
        for index in 1...Self.largePayloadBurstSize {
            pushUserMessage(store, id: "m\(index)", content: payload)
        }
        #expect(
            store.streamEventBuffer.count < Self.largePayloadBurstSize,
            "a few oversized events must trip the byte budget"
        )

        fake.responseMap["agent.getConversation"] = ["messages": [userRow(id: "r1")]]
        await settleInitialFetch(fake, fetch)

        #expect(store.streamEventBuffer.isEmpty)
        try await waitUntil("the authoritative state fetch") { fake.paramsForMethod("agent.get").count == 1 }
        try await waitUntil("the recovery refetch to land") { store.messages.map(\.id) == ["r1"] }
    }

    @Test func overflowWithLiveChatChannelReconcilesStateWithoutRefetch() async throws {
        let (store, fake, fetch) = try await makeLoadingStore(chatLive: true)
        for index in 1...Self.countBurstSize {
            pushStreamEvent(store, type: "agent:queue:processing", extra: ["messageId": "q\(index)"])
        }
        #expect(store.streamEventBuffer.count < Self.countBurstSize)

        await settleInitialFetch(fake, fetch)

        try await waitUntil("the authoritative state fetch") { fake.paramsForMethod("agent.get").count == 1 }
        try await expectNever("a transcript refetch while the live channel is authoritative") {
            fake.paramsForMethod("agent.getConversation").count > 1
        }
    }
}
