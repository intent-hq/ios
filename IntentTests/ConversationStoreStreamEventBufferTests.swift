import Foundation
@testable import Intent
import Testing

private struct LoadingStore {
    let store: ConversationStore
    let fake: FakeConnectionManager
    let fetch: Task<Void, Never>
}

/// Shared fixture of the stream-event buffer suites below: a store parked in
/// its initial `agent.getConversation`, plus event and page builders.
@MainActor
private protocol StreamEventBufferSuite {}

extension StreamEventBufferSuite {
    static var countBurstSize: Int { 600 }
    static var largePayloadBytes: Int { 1 << 20 }
    static var largePayloadBurstSize: Int { 3 }

    func makeLoadingStore(chatLive: Bool = false) async throws -> LoadingStore {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.getConversation")
        fake.responseMap["agent.get"] = ["agent": ["id": "a", "isStreaming": false] as [String: Any]]
        let store = ConversationStore(connectionManager: fake)
        if chatLive { seedLiveChatChannel(store) }
        let fetch = Task { await store.fetchConversation(agentId: "a", workspaceId: "w") }
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(store.isLoading)
        return LoadingStore(store: store, fake: fake, fetch: fetch)
    }

    /// `chatLive` only flips once a seq-0 snapshot is applied (PROTOCOL §7.1);
    /// activating the channel alone leaves the store on the legacy path.
    func seedLiveChatChannel(_ store: ConversationStore) {
        store.setTestChatChannel(subscriptionId: "sub-chat-123")
        store.handleStreamEvent("subscription.push", params: [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": ["agentId": "a", "messages": [] as [[String: Any]]] as [String: Any]
        ] as [String: Any])
        #expect(!store.liveTranscript.shouldRefetchAfterLegacyStreamEnd)
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
        for index in 1...Self.countBurstSize {
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

    func settleInitialFetch(
        _ fake: FakeConnectionManager,
        _ fetch: Task<Void, Never>,
        page: [[String: Any]] = []
    ) async {
        fake.pendingMethods.remove("agent.getConversation")
        fake.resolvePending("agent.getConversation", with: ["messages": page] as [String: Any])
        await fetch.value
    }
}

/// Retention bound on `streamEventBuffer` while the initial
/// `agent.getConversation` is in flight (ios#380): a burst under budget
/// replays in order; a burst over budget is not retained and the store
/// reconciles from the daemon instead of replaying a lossy buffer.
@MainActor
struct ConversationStoreStreamEventBufferTests: StreamEventBufferSuite {
    // MARK: - Under budget

    @Test func burstUnderBudgetReplaysInOrder() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        let fetch = loading.fetch
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
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        let fetch = loading.fetch
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
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        let fetch = loading.fetch
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

    @Test func overflowStateIsClearedByReset() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        let fetch = loading.fetch
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
        fake.failPending("agent.getConversation", with: CancellationError())
        await fetch.value
    }

    @Test func overflowWithLiveChatChannelReconcilesStateWithoutRefetch() async throws {
        let loading = try await makeLoadingStore(chatLive: true)
        let store = loading.store
        let fake = loading.fake
        let fetch = loading.fetch
        overflowBuffer(store)
        #expect(store.streamEventBuffer.isEmpty)

        await settleInitialFetch(fake, fetch)

        try await waitUntil("the authoritative state fetch") { fake.paramsForMethod("agent.get").count == 1 }
        try await expectNever("a transcript refetch while the live channel is authoritative") {
            fake.paramsForMethod("agent.getConversation").count > 1
        }
    }
}

/// Lossy-buffer recovery (ios#380): the refetch runs inside a held load
/// window so events arriving meanwhile survive the older page, the daemon's
/// streaming state is the final authoritative step, and work scheduled under
/// a binding that `reset()` replaced never runs.
@MainActor
struct ConversationStoreStreamEventRecoveryTests: StreamEventBufferSuite {
    /// The recovery refetch lands on a populated transcript, where
    /// `mergeFetchedMessages` deletes rows absent from the page. A user message
    /// that arrives while that older page is pending must survive it.
    @Test func recoveryRefetchPreservesMessagesArrivingWhileItIsPending() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        overflowBuffer(store)

        fake.resolvePending("agent.getConversation", with: ["messages": [userRow(id: "r1")]] as [String: Any])
        await loading.fetch.value
        #expect(store.messages.map(\.id) == ["r1"])

        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(fake.paramsForMethod("agent.getConversation").count == 2, "overflow scheduled the recovery")
        #expect(store.isLoading, "the recovery refetch holds the load window open")

        pushUserMessage(store, id: "m-new")
        #expect(store.streamEventBuffer.count == 1, "events during recovery are buffered, not applied")
        #expect(store.messages.map(\.id) == ["r1"])

        fake.pendingMethods.remove("agent.getConversation")
        fake.resolvePending("agent.getConversation", with: ["messages": [userRow(id: "r1")]] as [String: Any])

        try await waitUntil("the buffered message to replay on top of the recovery page") {
            store.messages.map(\.id) == ["r1", "m-new"]
        }
        #expect(!store.isLoading)
        #expect(store.streamEventBuffer.isEmpty)
    }

    /// The replay runs while the initial load is still finishing; the recovery
    /// window must already be open when that finish lowers `isLoading`, or an
    /// event landing before the scheduled recovery task runs is applied and
    /// then deleted by the older recovery page.
    @Test func recoveryHoldsTheLoadWindowBeforeItsTaskStarts() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        await settleInitialFetch(fake, loading.fetch, page: [userRow(id: "r1")])
        #expect(!store.isLoading)
        #expect(store.messages.map(\.id) == ["r1"])

        fake.pendingMethods.insert("agent.getConversation")
        store.streamEventBufferOverflowed = true
        store.replayBufferedStreamEvents()
        #expect(store.isLoading, "the window opens synchronously, before the recovery task gets to run")

        pushUserMessage(store, id: "m-gap")
        #expect(store.streamEventBuffer.count == 1, "an event in the gap is buffered, not applied")
        #expect(store.messages.map(\.id) == ["r1"])

        try await fake.waitForPendingRequests("agent.getConversation")
        fake.pendingMethods.remove("agent.getConversation")
        fake.resolvePending("agent.getConversation", with: ["messages": [userRow(id: "r1")]] as [String: Any])

        try await waitUntil("the gap message to replay on top of the recovery page") {
            store.messages.map(\.id) == ["r1", "m-gap"]
        }
        #expect(!store.isLoading)
    }

    /// A recovery refetch that fails (or is cancelled) without a reset must
    /// still close the held window: `isLoading` lowers, the transcript keeps
    /// its rows, and events buffered meanwhile are applied rather than lost.
    @Test func recoveryRefetchFailureClosesTheHeldWindowAndReplays() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        await settleInitialFetch(fake, loading.fetch, page: [userRow(id: "r1")])

        fake.pendingMethods.insert("agent.getConversation")
        store.streamEventBufferOverflowed = true
        store.replayBufferedStreamEvents()
        #expect(store.isLoading)
        pushUserMessage(store, id: "m-gap")

        try await fake.waitForPendingRequests("agent.getConversation")
        fake.pendingMethods.remove("agent.getConversation")
        fake.failPending("agent.getConversation", with: CancellationError())

        try await waitUntil("the failed recovery to close its window") { !store.isLoading }
        #expect(store.liveTranscript.heldLoadWindows == 0)
        #expect(store.messages.map(\.id) == ["r1", "m-gap"])
        #expect(store.streamEventBuffer.isEmpty)
        #expect(store.agentId == "a")
    }

    /// The page refetch runs as a child task that hops to the main actor on
    /// its own; a reset landing between the recovery task's guard and that
    /// hop must stop the child before it rebinds the old agent.
    @Test func recoveryPageEntryDoesNotRebindAfterReset() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        await settleInitialFetch(fake, loading.fetch, page: [userRow(id: "r1")])
        let generation = store.liveTranscript.bindingGeneration

        store.reset()
        await store.fetchRecoveryPage(agentId: "a", generation: generation)

        #expect(store.agentId == nil)
        #expect(store.liveTranscript.agentId == nil)
        #expect(fake.paramsForMethod("agent.getConversation").count == 1)
        #expect(!store.isLoading)
    }

    /// Overflow can drop the `agent:stream:end`; when the initial page still
    /// shows the turn in progress but the daemon reports idle and the recovery
    /// page is complete, recovery must settle `isStreaming` back to false.
    @Test func recoveryClearsStaleStreamingWhenTheDaemonIsIdle() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        overflowBuffer(store)

        fake.responseMap["agent.getConversation"] = ["messages": [assistantRow(id: "as1", streaming: false)]]
        await settleInitialFetch(fake, loading.fetch, page: [assistantRow(id: "as1", streaming: true)])

        try await waitUntil("the daemon's idle reply to clear the stale streaming flag") { !store.isStreaming }
        #expect(fake.paramsForMethod("agent.get").count == 1)
        try await waitUntil("the recovery page to land") { fake.paramsForMethod("agent.getConversation").count == 2 }
        try await expectNever("streaming to be raised again without a live event") { store.isStreaming }
    }

    /// The recovery page and the daemon's state reply must not race: a page
    /// whose last assistant row is still marked streaming cannot be allowed to
    /// override the authoritative idle answer, so the state reconcile is the
    /// final step of recovery.
    @Test func recoveryStateSettlesAfterAStaleStreamingPage() async throws {
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        await settleInitialFetch(fake, loading.fetch, page: [assistantRow(id: "as1", streaming: true)])
        #expect(store.isStreaming)

        fake.pendingMethods.insert("agent.getConversation")
        store.streamEventBufferOverflowed = true
        store.replayBufferedStreamEvents()
        try await fake.waitForPendingRequests("agent.getConversation")
        fake.pendingMethods.remove("agent.getConversation")
        fake.resolvePending(
            "agent.getConversation",
            with: ["messages": [assistantRow(id: "as1", streaming: true)]] as [String: Any]
        )

        try await waitUntil("the daemon's idle reply to settle streaming after the stale page") { !store.isStreaming }
        try await waitUntil("recovery to close its window") { !store.isLoading }
        #expect(fake.paramsForMethod("agent.get").count == 1)
        try await expectNever("streaming to be raised again without a live event") { store.isStreaming }
    }

    /// A stale `agent.get` reply must not undo what the authoritative live
    /// channel applied while it was in flight — in either direction.
    @Test func recoveryStateFetchYieldsToNewerLiveChannelActivity() async throws {
        let loading = try await makeLoadingStore(chatLive: true)
        let store = loading.store
        let fake = loading.fake
        fake.pendingMethods.insert("agent.get")
        overflowBuffer(store)
        await settleInitialFetch(fake, loading.fetch)
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
        let loading = try await makeLoadingStore()
        let store = loading.store
        let fake = loading.fake
        store.streamEventBufferBudget = StreamEventBufferBudget(maxEvents: 2, maxBytes: .max)
        for index in 1...3 { pushUserMessage(store, id: "m\(index)") }
        #expect(store.streamEventBufferOverflowed)

        store.replayBufferedStreamEvents()
        store.reset()
        #expect(store.agentId == nil)

        fake.failPending("agent.getConversation", with: CancellationError())
        await loading.fetch.value

        try await expectNever("recovery work for the reset binding") {
            !fake.paramsForMethod("agent.get").isEmpty
                || fake.paramsForMethod("agent.getConversation").count > 1
                || store.agentId != nil
                || store.liveTranscript.agentId != nil
        }
        #expect(!store.isLoading)
    }
}
