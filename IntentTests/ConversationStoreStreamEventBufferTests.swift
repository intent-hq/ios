import Foundation
@testable import Intent
import Testing

private let kCountBurstSize = 600
private let kLargePayloadBytes = 1 << 20
private let kLargePayloadBurstSize = 3

private struct LoadingStore {
    let store: ConversationStore
    let fake: FakeConnectionManager
}

/// Shared fixture of the stream-event buffer suites below: a store whose
/// `chat.subscribe` registration is acked but whose seq-0 snapshot has not
/// landed yet (`isLoading`), plus event and row builders.
@MainActor
private protocol StreamEventBufferSuite {}

extension StreamEventBufferSuite {
    func makeLoadingStore() async -> LoadingStore {
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat-123"]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.get"] = ["agent": ["id": "a", "isStreaming": false] as [String: Any]]
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.isLoading)
        return LoadingStore(store: store, fake: fake)
    }

    func pushUserMessage(_ store: ConversationStore, id: String, content: String = "hi") {
        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:user-message:sent",
                "data": ["agentId": "a", "messageId": id, "content": content]
            ] as [String: Any]
        ])
    }

    func pushStreamEvent(_ store: ConversationStore, type: String, extra: [String: Any] = [:]) {
        var data: [String: Any] = ["agentId": "a"]
        for (key, value) in extra { data[key] = value }
        store.handleStreamEvent("events.event", params: [
            "event": ["type": type, "data": data] as [String: Any]
        ])
    }

    /// Block-level chat delta (PROTOCOL §7.1) carrying one assistant block.
    func pushAssistantDelta(
        _ store: ConversationStore,
        seq: Int,
        messageId: String,
        text: String,
        streamingComplete: Bool = false
    ) {
        var entity: [String: Any] = [
            "agentId": "a",
            "messageId": messageId,
            "role": "assistant",
            "block": ["type": "text", "id": "\(messageId):0", "text": text] as [String: Any]
        ]
        if streamingComplete { entity["streamingComplete"] = true }
        store.handleStreamEvent("subscription.push", params: [
            "subscriptionId": "sub-chat-123",
            "kind": "delta",
            "seq": seq,
            "delta": ["added": [entity], "updated": [] as [[String: Any]], "removedIds": [] as [String]]
        ] as [String: Any])
    }

    func overflowBuffer(_ store: ConversationStore) {
        for index in 1...kCountBurstSize {
            pushStreamEvent(store, type: "agent:queue:processing", extra: ["messageId": "q\(index)"])
        }
        #expect(store.streamEventBufferOverflowed)
    }

    func userRow(id: String) -> [String: Any] {
        [
            "id": id,
            "role": "user",
            "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": "hi"]]
        ]
    }

    func assistantRow(id: String, streaming: Bool) -> [String: Any] {
        [
            "id": id,
            "role": "assistant",
            "timestamp": "2024-01-01T00:00:01Z",
            "isStreaming": streaming,
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": "Working"]]
        ]
    }

    /// Lands the seq-0 snapshot the pending registration owes.
    func settleInitialLoad(_ fake: FakeConnectionManager, rows: [[String: Any]] = []) {
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-chat-123",
            seq: 0,
            conversationSnapshot: rows,
            metadata: ["truncated": false, "totalMessages": rows.count]
        ))
    }
}

/// Retention bound on `streamEventBuffer` while the initial `chat.subscribe`
/// snapshot is pending (ios#380): the snapshot that ends the load is the
/// authoritative transcript, so a burst under budget is released without
/// replaying over it; a burst over budget is not retained and the store
/// reconciles its streaming state from the daemon instead.
@MainActor
struct ConversationStoreStreamEventBufferTests: StreamEventBufferSuite {
    // MARK: - Under budget

    @Test func burstUnderBudgetYieldsToTheSnapshot() async throws {
        let loading = await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        let ids = (1...8).map { "m\($0)" }
        pushStreamEvent(store, type: "agent:stream:start", extra: ["streamId": "s1"])
        for id in ids { pushUserMessage(store, id: id) }
        #expect(store.streamEventBuffer.count == ids.count + 1)
        #expect(store.messages.isEmpty, "events are buffered, not applied, while the snapshot is pending")

        settleInitialLoad(fake, rows: [userRow(id: "r1")])

        #expect(!store.isLoading)
        #expect(store.streamEventBuffer.isEmpty, "the buffer is released once the load settles")
        #expect(store.messages.map(\.id) == ["r1"], "the snapshot is the transcript; nothing replays over it")
        #expect(!store.isStreaming, "the idle snapshot settles the streaming state")
        try await expectNever("a recovery fetch for an under-budget burst") {
            fake.paramsForMethod("chat.subscribe").count > 1 || !fake.paramsForMethod("agent.get").isEmpty
        }
    }

    // MARK: - Over budget

    @Test func burstOverCountBudgetIsBoundedAndReconcilesFromTheDaemon() async throws {
        let loading = await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        for index in 1...kCountBurstSize { pushUserMessage(store, id: "m\(index)") }
        #expect(
            store.streamEventBuffer.count < kCountBurstSize,
            "retention while loading must be bounded, not proportional to the burst"
        )

        settleInitialLoad(fake, rows: [userRow(id: "r1"), userRow(id: "r2")])

        #expect(store.streamEventBuffer.isEmpty)
        #expect(store.messages.map(\.id) == ["r1", "r2"])
        try await waitUntil("the authoritative state fetch") { fake.paramsForMethod("agent.get").count == 1 }
        try await expectNever("a transcript re-registration while the live channel is authoritative") {
            fake.paramsForMethod("chat.subscribe").count > 1
        }
    }

    @Test func burstOverByteBudgetIsBoundedAndReconcilesFromTheDaemon() async throws {
        let loading = await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        let payload = String(repeating: "x", count: kLargePayloadBytes)
        for index in 1...kLargePayloadBurstSize {
            pushUserMessage(store, id: "m\(index)", content: payload)
        }
        #expect(
            store.streamEventBuffer.count < kLargePayloadBurstSize,
            "a few oversized events must trip the byte budget"
        )

        settleInitialLoad(fake, rows: [userRow(id: "r1")])

        #expect(store.streamEventBuffer.isEmpty)
        #expect(store.messages.map(\.id) == ["r1"])
        try await waitUntil("the authoritative state fetch") { fake.paramsForMethod("agent.get").count == 1 }
    }

    @Test func overflowStateIsClearedByReset() async {
        let loading = await makeLoadingStore()
        let store = loading.store
        store.streamEventBufferBudget = StreamEventBufferBudget(maxEvents: 2, maxBytes: .max)
        pushUserMessage(store, id: "m1")
        pushUserMessage(store, id: "m2")
        #expect(store.streamEventBuffer.count == 2)
        #expect(store.streamEventBufferBytes > 0)
        #expect(!store.streamEventBufferOverflowed)

        pushUserMessage(store, id: "m3")
        #expect(store.streamEventBufferOverflowed, "the third event trips a two-event budget")
        #expect(store.streamEventBuffer.isEmpty, "an overflowed buffer retains nothing")
        #expect(store.streamEventBufferBytes == 0)

        store.reset()
        #expect(!store.streamEventBufferOverflowed)
        #expect(store.streamEventBufferBytes == 0)
        #expect(!store.isLoading)
    }
}

/// Lossy-buffer recovery (ios#380): the seq-0 snapshot is the transcript, so
/// recovery only reconciles the streaming state from the daemon — that reply
/// is the final authoritative step, yields to newer live-channel activity,
/// and work scheduled under a binding that `reset()` replaced never runs.
@MainActor
struct ConversationStoreStreamRecoveryTests: StreamEventBufferSuite {
    /// Overflow can drop the `agent:stream:end`; when the snapshot still shows
    /// the turn in progress but the daemon reports idle, recovery must settle
    /// `isStreaming` back to false.
    @Test func recoveryClearsStaleStreamingWhenTheDaemonIsIdle() async throws {
        let loading = await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        overflowBuffer(store)

        settleInitialLoad(fake, rows: [assistantRow(id: "as1", streaming: true)])
        #expect(store.messages.map(\.id) == ["as1"])

        try await waitUntil("the daemon's idle reply to clear the stale streaming flag") { !store.isStreaming }
        #expect(fake.paramsForMethod("agent.get").count == 1)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1, "recovery never re-registers the channel")
        try await expectNever("streaming to be raised again without a live event") { store.isStreaming }
    }

    /// A stale `agent.get` reply must not undo what the authoritative live
    /// channel applied while it was in flight — in either direction.
    @Test func recoveryStateFetchYieldsToNewerLiveChannelActivity() async throws {
        let loading = await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        fake.pendingMethods.insert("agent.get")
        overflowBuffer(store)
        settleInitialLoad(fake)
        try await fake.waitForPendingRequests("agent.get")

        pushAssistantDelta(store, seq: 1, messageId: "as1", text: "Partial")
        #expect(store.isStreaming)
        pushAssistantDelta(store, seq: 2, messageId: "as1", text: "Partial + final.", streamingComplete: true)
        #expect(!store.isStreaming)

        fake.resolvePending("agent.get", with: [
            "agent": ["id": "a", "isStreaming": true, "metadata": ["lastSeenMessageId": "seen-1"]] as [String: Any]
        ] as [String: Any])
        try await waitUntil("the stale state reply to be processed") { store.lastSeenMessageId == "seen-1" }
        #expect(!store.isStreaming, "a stale streaming=true reply must not override the terminal delta")

        // Inverse order: an idle reply landing after a newer delta raised streaming.
        store.streamEventBufferOverflowed = true
        store.replayBufferedStreamEvents()
        try await fake.waitForPendingRequests("agent.get")
        pushAssistantDelta(store, seq: 3, messageId: "as2", text: "Again")
        #expect(store.isStreaming)
        fake.resolvePending("agent.get", with: [
            "agent": ["id": "a", "isStreaming": false, "metadata": ["lastSeenMessageId": "seen-2"]] as [String: Any]
        ] as [String: Any])
        try await waitUntil("the stale idle reply to be processed") { store.lastSeenMessageId == "seen-2" }
        #expect(store.isStreaming, "a stale idle reply must not lower streaming the live channel raised")
    }

    /// Recovery scheduled by the replay must not run against a binding that
    /// `reset()` replaced before it started: no requests for the old agent and
    /// no rebind of the reset store.
    @Test func resetBeforeScheduledRecoveryStartsInvalidatesIt() async throws {
        let loading = await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        store.streamEventBufferBudget = StreamEventBufferBudget(maxEvents: 2, maxBytes: .max)
        for index in 1...3 { pushUserMessage(store, id: "m\(index)") }
        #expect(store.streamEventBufferOverflowed)

        store.replayBufferedStreamEvents()
        store.reset()
        #expect(store.agentId == nil)

        try await expectNever("recovery work for the reset binding") {
            !fake.paramsForMethod("agent.get").isEmpty
                || fake.paramsForMethod("chat.subscribe").count > 1
                || store.agentId != nil
                || store.liveTranscript.agentId != nil
        }
        #expect(!store.isLoading)
    }
}
