import Foundation
@testable import Intent
import Testing

// Extracted wire fixtures intentionally mirror the daemon payloads inline.
// swiftlint:disable multiline_arguments multiline_call_arguments multiline_literal_brackets no_magic_numbers

extension ConversationStoreLiveStateTests {
    /// Agent B's seq-0 snapshot row.
    var agentBRow: [String: Any] {
        [
            "id": "msg-b1", "role": "user",
            "contentBlocks": [["type": "text", "id": "msg-b1:0", "text": "Hello B"]],
            "timestamp": "2026-06-27T02:00:00.000Z"
        ]
    }

    /// Parks agent A's `chat.subscribe` in flight (its `isLoading` raised).
    private func startPendingSubscribeForAgentA(
        _ store: ConversationStore,
        _ fake: FakeConnectionManager
    ) async -> Task<Void, Never> {
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        fake.pendingMethods = ["chat.subscribe"]
        let subscribeA = Task { await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1") }
        while fake.paramsForMethod("chat.subscribe").count < 1 {
            await Task.yield()
        }
        #expect(store.isLoading)
        return subscribeA
    }

    /// Rebind the store to agent B (`chat.subscribe` → `liveTranscript.subscribe`
    /// binds synchronously) and seed B's transcript from its live snapshot.
    private func rebindToAgentB(_ store: ConversationStore, _ fake: FakeConnectionManager) async {
        fake.pendingMethods = []
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat-123"]
        await store.subscribeLiveChat(agentId: "agent-b")
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [agentBRow]))
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.isStreaming == false)
    }

    func expectAgentBTranscriptIntact(_ store: ConversationStore) {
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.messages.first?.contentBlocks.first?.resolvedText == "Hello B")
        #expect(store.isStreaming == false)
        #expect(store.isTruncated == false)
        #expect(store.totalMessageCount == 1)
    }

    @Test func staleSubscribeResolvedAfterRebindDoesNotOverwriteNewAgent() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        // Rebind while A's registration is still in flight, then let A's ack arrive.
        await rebindToAgentB(store, fake)
        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-a"])
        await subscribeA.value

        expectAgentBTranscriptIntact(store)
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"), "A's orphaned registration is not wired up")
        // A's registration released the test channel it replaced; B found
        // nothing acked to release; A's late ack is released as an orphan.
        #expect(
            fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String }
                == ["sub-chat-123", "sub-a"]
        )
        // B's snapshot settled the shared loading flag A raised.
        #expect(store.isLoading == false)
    }

    /// A stale registration for agent A must not finish agent B's own
    /// in-flight initial load: `isLoading` stays up, and the streaming flag
    /// the firehose raised meanwhile is settled by B's snapshot, the
    /// authoritative transcript.
    @Test func staleSubscribeDoesNotFinishNewAgentInFlightInitialLoad() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        // Rebind to B via its own pending registration (messages stay empty).
        let subscribeB = Task { await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1") }
        while fake.paramsForMethod("chat.subscribe").count < 2 {
            await Task.yield()
        }
        #expect(store.isLoading)

        // The channel has not seeded yet, so the firehose is the liveness signal.
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:stream:activity",
                      "data": ["agentId": "agent-b"]] as [String: Any]
        ])
        #expect(store.isStreaming, "activity raises the flag while the channel is not live")
        #expect(store.messages.isEmpty, "activity never mutates the transcript")

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-a"])
        await subscribeA.value

        #expect(store.isLoading, "stale A must not clear B's in-flight initial load")
        #expect(store.messages.isEmpty)

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-chat-123"])
        await subscribeB.value
        #expect(store.isLoading, "an acked registration still awaits its seq-0 snapshot")
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [agentBRow]))

        #expect(store.isLoading == false)
        #expect(store.isStreaming == false, "the idle snapshot is authoritative over the firehose activity")
        #expect(store.messages.map(\.id) == ["msg-b1"])
    }

    /// Same as above, but A's stale registration *fails* (cancellation, as
    /// the real ConnectionManager throws on task cancellation): the stale
    /// error is dropped, and it must not finish B's in-flight initial load.
    @Test func staleSubscribeFailureDoesNotFinishNewAgentInFlightInitialLoad() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        let subscribeB = Task { await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1") }
        while fake.paramsForMethod("chat.subscribe").count < 2 {
            await Task.yield()
        }
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:stream:activity",
                      "data": ["agentId": "agent-b"]] as [String: Any]
        ])

        subscribeA.cancel()
        await subscribeA.value

        #expect(store.isLoading, "a failed stale A must not clear B's in-flight initial load")
        #expect(store.liveTranscript.chatChannelActive, "A's failure must not tear down B's channel")

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-chat-123"])
        await subscribeB.value
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [agentBRow]))

        #expect(store.isLoading == false)
        #expect(store.isStreaming == false, "the idle snapshot settles the flag the firehose raised")
        #expect(store.messages.map(\.id) == ["msg-b1"])
    }

    /// A definitive not-found for agent A that lands after the transcript was
    /// rebound to agent B says nothing about B: it must not reach
    /// `onSubscribeError` and flag the new binding as deleted (intent-hq/ios#283).
    @Test func staleNotFoundForPreviousAgentDoesNotFlagNewBinding() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        await rebindToAgentB(store, fake)
        fake.failPending("chat.subscribe", with: definitiveNotFound(agentId: "agent-a"))
        await subscribeA.value

        #expect(!store.agentNotFound,
                "a not-found for the previous agent must not mark the current one deleted")
        expectAgentBTranscriptIntact(store)
        #expect(store.liveTranscript.chatChannelActive, "A's rejection must not tear down B's channel")
        #expect(store.isLoading == false)
    }

    /// Counterpart: the same in-flight failure for the agent that is *still*
    /// bound keeps raising `agentNotFound`.
    @Test func notFoundForStillBoundAgentRaisesAgentNotFound() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        fake.failPending("chat.subscribe", with: definitiveNotFound(agentId: "agent-a"))
        await subscribeA.value

        #expect(store.agentNotFound, "a definitive not-found for the bound agent must raise agentNotFound")
        #expect(!store.liveTranscript.chatChannelActive, "a rejected registration leaves no live channel")
    }

    /// `-32602` with `data.code == "not-found"` (docs/PROTOCOL.md §3.3/§9).
    private func definitiveNotFound(agentId: String) -> NSError {
        NSError(
            domain: "WebSocket", code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "unknown agent id: \(agentId)",
                       NSError.intentErrorDataCodeKey: "not-found"]
        )
    }

    // MARK: - Structural binding guard (`whileBound`)

    /// A `whileBound` body that suspends while the transcript is rebound to a
    /// different agent must have its result suppressed; a same-agent rebind in
    /// the same window must not (concurrent same-agent channel work keeps merging).
    @Test func whileBoundSuppressesResultOnlyWhenBoundAgentChanges() async {
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        let transcript = ConversationLiveTranscript(connectionManager: fake)
        await transcript.subscribe(agentId: "agent-a")

        fake.pendingMethods = ["test.pending"]
        let crossAgent = Task { () -> Int? in
            await transcript.whileBound {
                _ = try? await fake.request("test.pending")
                return 1
            }
        }
        while !fake.didCallMethod("test.pending") {
            await Task.yield()
        }
        await transcript.subscribe(agentId: "agent-b")
        fake.resolvePending("test.pending", with: [String: Any]())
        #expect(await crossAgent.value == nil)

        fake.clearRequestLog()
        let sameAgent = Task { () -> Int? in
            await transcript.whileBound {
                _ = try? await fake.request("test.pending")
                return 2
            }
        }
        while !fake.didCallMethod("test.pending") {
            await Task.yield()
        }
        await transcript.subscribe(agentId: "agent-b")
        fake.resolvePending("test.pending", with: [String: Any]())
        #expect(await sameAgent.value == 2)
    }

    @Test func staleHydrateBlockResolvedAfterRebindDoesNotTouchNewAgent() async {
        let (store, fake) = makeStore()
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [
            [
                "id": "msg-a1", "role": "assistant", "timestamp": "2026-06-27T01:00:00.000Z",
                "contentBlocks": [
                    ["type": "tool_result", "id": "b-1", "toolUseId": "tc-1",
                     "output": "p", "outputTruncated": true]
                ]
            ]
        ])
        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store.messages.map(\.id) == ["msg-a1"])

        fake.pendingMethods = ["agent.getMessageBlock"]
        let hydration = Task { await store.hydrateBlock(messageId: "msg-a1", blockId: "b-1") }
        while !fake.didCallMethod("agent.getMessageBlock") {
            await Task.yield()
        }

        await rebindToAgentB(store, fake)
        fake.resolvePending("agent.getMessageBlock", with: ["block": [
            "type": "tool_result", "id": "b-1", "toolUseId": "tc-1", "output": "full"
        ] as [String: Any]])
        await hydration.value

        #expect(!store.isBlockHydrated(messageId: "msg-a1", blockId: "b-1"))
        #expect(store.hydratingBlockKeys.isEmpty)
        expectAgentBTranscriptIntact(store)
    }

    /// A `chat.subscribe` reply for agent A that lands after the transcript was
    /// rebound to agent B must neither re-point the push handler nor overwrite
    /// B's active subscription id, and A's orphaned subscription is released.
    @Test func staleSubscribeReplyAfterRebindKeepsNewAgentChannel() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.unsubscribe"] = [String: Any]()

        fake.pendingMethods = ["chat.subscribe"]
        let subscribeA = Task { await store.subscribeLiveChat(agentId: "agent-a") }
        while !fake.didCallMethod("chat.subscribe") {
            await Task.yield()
        }

        // B's subscribe resolves immediately with its own id while A's is in flight.
        fake.pendingMethods = []
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-b"]
        await store.subscribeLiveChat(agentId: "agent-b")
        #expect(fake.hasSubscriptionHandler(id: "sub-b"))

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-a"])
        await subscribeA.value

        #expect(fake.hasSubscriptionHandler(id: "sub-b"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))
        let unsubscribed = fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String }
        #expect(unsubscribed == ["sub-a"])

        // A push tagged with A's id is ignored; one tagged with B's id is applied.
        var stalePush = snapshotParams(messages: [
            [
                "id": "msg-a1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-a1:0", "text": "Stale A"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ])
        stalePush["subscriptionId"] = "sub-a"
        store.handleStreamEvent("subscription.push", params: stalePush)
        #expect(store.messages.isEmpty)

        var livePush = snapshotParams(messages: [
            [
                "id": "msg-b1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-b1:0", "text": "Hello B"]],
                "timestamp": "2026-06-27T02:00:00.000Z"
            ]
        ])
        livePush["subscriptionId"] = "sub-b"
        store.handleStreamEvent("subscription.push", params: livePush)
        #expect(store.messages.map(\.id) == ["msg-b1"])
    }
}

// swiftlint:enable multiline_arguments multiline_call_arguments multiline_literal_brackets no_magic_numbers
