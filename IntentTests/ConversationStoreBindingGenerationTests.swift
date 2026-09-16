import Foundation
@testable import Intent
import Testing

// Extracted wire fixtures intentionally mirror the daemon payloads inline.
// swiftlint:disable multiline_arguments multiline_call_arguments multiline_literal_brackets no_magic_numbers

extension ConversationStoreLiveStateTests {
    /// Agent A's page (truncated, with an in-flight assistant message) that
    /// must never land once the transcript is bound to agent B.
    private var stalePageForAgentA: [String: Any] {
        [
            "messages": [
                [
                    "id": "msg-a1", "role": "assistant",
                    "contentBlocks": [["type": "text", "id": "msg-a1:0", "text": "Stale A"]],
                    "timestamp": "2026-06-27T01:00:00.000Z",
                    "isStreaming": true
                ]
            ],
            "truncated": true,
            "totalMessages": 42
        ]
    }

    /// Rebind the store to agent B (`chat.subscribe` → `liveTranscript.subscribe`
    /// binds synchronously) and seed B's transcript from its live snapshot.
    private func rebindToAgentB(_ store: ConversationStore, _ fake: FakeConnectionManager) async {
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat-123"]
        await store.subscribeLiveChat(agentId: "agent-b")
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-b1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-b1:0", "text": "Hello B"]],
                "timestamp": "2026-06-27T02:00:00.000Z"
            ]
        ]))
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.isStreaming == false)
    }

    private func expectAgentBTranscriptIntact(_ store: ConversationStore) {
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.messages.first?.contentBlocks.first?.resolvedText == "Hello B")
        #expect(store.isStreaming == false)
        #expect(store.isTruncated == false)
        #expect(store.totalMessageCount == 1)
    }

    @Test func staleFetchResolvedAfterRebindDoesNotOverwriteNewAgent() async {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchTask = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }

        // Rebind while A's request is still in flight, then let A's page arrive.
        await rebindToAgentB(store, fake)
        fake.resolvePending("agent.getConversation", with: stalePageForAgentA)
        await fetchTask.value

        expectAgentBTranscriptIntact(store)
        // B has no initial load in flight, so the stale fetch still releases
        // the shared loading flag it raised.
        #expect(store.isLoading == false)
    }

    /// A stale initial fetch for agent A must not finish agent B's own
    /// in-flight initial load: `isLoading` stays up and buffered firehose
    /// events are replayed only when B's page lands.
    @Test func staleInitialFetchDoesNotFinishNewAgentInFlightInitialLoad() async {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchA = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while fake.paramsForMethod("agent.getConversation").count < 1 {
            await Task.yield()
        }

        // Rebind to B via its own initial fetch (no snapshot: messages stay empty).
        let fetchB = Task { await store.fetchConversation(agentId: "agent-b", workspaceId: "ws-1") }
        while fake.paramsForMethod("agent.getConversation").count < 2 {
            await Task.yield()
        }
        #expect(store.isLoading)

        // Buffered while loading; a replay would flip isStreaming.
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:stream:activity",
                      "data": ["agentId": "agent-b"]] as [String: Any]
        ])
        #expect(store.isStreaming == false)

        fake.resolvePending("agent.getConversation", with: stalePageForAgentA)
        await fetchA.value

        #expect(store.isLoading, "stale A must not clear B's in-flight initial load")
        #expect(store.isStreaming == false, "buffered replay must wait for B's page")
        #expect(store.messages.isEmpty)

        fake.resolvePending("agent.getConversation", with: [
            "messages": [
                [
                    "id": "msg-b1", "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-b1:0", "text": "Hello B"]],
                    "timestamp": "2026-06-27T02:00:00.000Z"
                ]
            ]
        ])
        await fetchB.value

        #expect(store.isLoading == false)
        #expect(store.isStreaming, "buffered activity replays once B's initial load completes")
        #expect(store.messages.map(\.id) == ["msg-b1"])
    }

    /// Same as above, but A's stale initial fetch *fails* (cancellation, as
    /// the real ConnectionManager throws on task cancellation): the stale
    /// error is dropped, and it must not finish B's in-flight initial load.
    @Test func staleInitialFetchFailureDoesNotFinishNewAgentInFlightInitialLoad() async {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchA = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while fake.paramsForMethod("agent.getConversation").count < 1 {
            await Task.yield()
        }

        let fetchB = Task { await store.fetchConversation(agentId: "agent-b", workspaceId: "ws-1") }
        while fake.paramsForMethod("agent.getConversation").count < 2 {
            await Task.yield()
        }
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:stream:activity",
                      "data": ["agentId": "agent-b"]] as [String: Any]
        ])

        fetchA.cancel()
        await fetchA.value

        #expect(store.isLoading, "a failed stale A must not clear B's in-flight initial load")
        #expect(store.isStreaming == false, "buffered replay must wait for B's page")

        fake.resolvePending("agent.getConversation", with: [
            "messages": [
                [
                    "id": "msg-b1", "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-b1:0", "text": "Hello B"]],
                    "timestamp": "2026-06-27T02:00:00.000Z"
                ]
            ]
        ])
        await fetchB.value

        #expect(store.isLoading == false)
        #expect(store.isStreaming)
        #expect(store.messages.map(\.id) == ["msg-b1"])
    }

    @Test func staleFetchRebindDuringDecodeDoesNotOverwriteNewAgent() async {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchTask = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }

        // A's response arrives while A is still bound; the fetch resumes on
        // MainActor and hops off for the @concurrent decode. Rebinding to B in
        // that post-response window must still drop A's page.
        fake.resolvePending("agent.getConversation", with: stalePageForAgentA)
        await Task.yield()
        await rebindToAgentB(store, fake)
        await fetchTask.value

        expectAgentBTranscriptIntact(store)
    }

    /// A definitive not-found for agent A that lands after the transcript was
    /// rebound to agent B says nothing about B: it must not reach
    /// `onFetchError` and flag the new binding as deleted (intent-hq/ios#283).
    @Test func staleNotFoundForPreviousAgentDoesNotFlagNewBinding() async {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchTask = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }

        await rebindToAgentB(store, fake)
        fake.failPending("agent.getConversation", with: definitiveNotFound(agentId: "agent-a"))
        await fetchTask.value

        #expect(!store.agentNotFound,
                "a not-found for the previous agent must not mark the current one deleted")
        expectAgentBTranscriptIntact(store)
        #expect(store.isLoading == false)
    }

    /// Counterpart: the same in-flight failure for the agent that is *still*
    /// bound keeps raising `agentNotFound`.
    @Test func notFoundForStillBoundAgentRaisesAgentNotFound() async {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchTask = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }

        fake.failPending("agent.getConversation", with: definitiveNotFound(agentId: "agent-a"))
        await fetchTask.value

        #expect(store.agentNotFound, "a definitive not-found for the bound agent must raise agentNotFound")
        #expect(store.isLoading == false)
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
    /// the same window must not (concurrent same-agent fetches keep merging).
    @Test func whileBoundSuppressesResultOnlyWhenBoundAgentChanges() async {
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        let transcript = ConversationLiveTranscript(connectionManager: fake)
        await transcript.subscribe(agentId: "agent-a")

        fake.pendingMethods = ["agent.getConversation"]
        let crossAgent = Task { () -> Int? in
            await transcript.whileBound {
                _ = try? await fake.request("agent.getConversation")
                return 1
            }
        }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }
        await transcript.subscribe(agentId: "agent-b")
        fake.resolvePending("agent.getConversation", with: [String: Any]())
        #expect(await crossAgent.value == nil)

        fake.clearRequestLog()
        let sameAgent = Task { () -> Int? in
            await transcript.whileBound {
                _ = try? await fake.request("agent.getConversation")
                return 2
            }
        }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }
        await transcript.subscribe(agentId: "agent-b")
        fake.resolvePending("agent.getConversation", with: [String: Any]())
        #expect(await sameAgent.value == 2)
    }

    @Test func staleHydrateBlockResolvedAfterRebindDoesNotTouchNewAgent() async {
        let (store, fake) = makeStore()
        fake.responseMap["agent.getConversation"] = ["messages": [
            [
                "id": "msg-a1", "role": "assistant", "timestamp": "2026-06-27T01:00:00.000Z",
                "contentBlocks": [
                    ["type": "tool_result", "id": "b-1", "toolUseId": "tc-1",
                     "output": "p", "outputTruncated": true]
                ]
            ]
        ]]
        await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1")

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
