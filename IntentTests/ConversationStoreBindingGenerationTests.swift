import Foundation
@testable import Intent
import Testing

// swiftlint:disable no_magic_numbers

extension ConversationStoreLiveStateTests {
    var agentBRow: [String: Any] {
        [
            "id": "msg-b1", "role": "user",
            "contentBlocks": [["type": "text", "id": "msg-b1:0", "text": "Hello B"]],
            "timestamp": "2026-06-27T02:00:00.000Z"
        ]
    }

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

    @Test func staleSubscribeResolvedAfterRebindDoesNotOverwriteNewAgent() async throws {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        await rebindToAgentB(store, fake)
        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-a"])
        await subscribeA.value

        expectAgentBTranscriptIntact(store)
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"), "A's orphaned registration is not wired up")
        try await fake.waitForRequests("chat.unsubscribe", count: 2)
        #expect(
            fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String }
                == ["sub-chat-123", "sub-a"]
        )
        #expect(store.isLoading == false)
    }

    @Test func staleSubscribeDoesNotFinishNewAgentInFlightInitialLoad() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        let subscribeB = Task { await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1") }
        while fake.paramsForMethod("chat.subscribe").count < 2 {
            await Task.yield()
        }
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:stream:activity",
                "data": ["agentId": "agent-b"]
            ] as [String: Any]
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

    @Test func staleSubscribeFailureDoesNotFinishNewAgentInFlightInitialLoad() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        let subscribeB = Task { await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1") }
        while fake.paramsForMethod("chat.subscribe").count < 2 {
            await Task.yield()
        }
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:stream:activity",
                "data": ["agentId": "agent-b"]
            ] as [String: Any]
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

    @Test func notFoundForStillBoundAgentRaisesAgentNotFound() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        fake.failPending("chat.subscribe", with: definitiveNotFound(agentId: "agent-a"))
        await subscribeA.value

        #expect(store.agentNotFound, "a definitive not-found for the bound agent must raise agentNotFound")
        #expect(!store.liveTranscript.chatChannelActive, "a rejected registration leaves no live channel")
        #expect(!store.liveTranscript.snapshotPending, "no snapshot is owed for a deleted agent")
        #expect(!store.isLoading, "a definitive not-found settles the initial load")
    }

    @Test func rebindHandsLivenessToTheFirehoseUntilTheNewSnapshotApplies() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        fake.stubChatSnapshot(subscriptionId: "sub-a")
        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store.liveTranscript.chatLive)

        fake.pendingMethods = ["chat.subscribe"]
        let subscribeB = Task { await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1") }
        try await waitUntil("agent B's registration") { fake.paramsForMethod("chat.subscribe").count == 2 }
        #expect(!store.liveTranscript.chatLive, "the released channel must not own B's liveness")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["agentId": "agent-b", "streamId": "s-b"]]
        ])
        #expect(store.isStreaming, "the firehose is B's only liveness signal while its snapshot is pending")

        fake.stubChatSnapshot(subscriptionId: "sub-b", messages: [agentBRow])
        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-b"])
        await subscribeB.value

        #expect(store.liveTranscript.chatLive)
        expectAgentBTranscriptIntact(store)
    }

    private func definitiveNotFound(agentId: String) -> NSError {
        NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: \(agentId)",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
    }

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
                    [
                        "type": "tool_result", "id": "b-1", "toolUseId": "tc-1",
                        "output": "p", "outputTruncated": true
                    ]
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
        fake.resolvePending("agent.getMessageBlock", with: [
            "block": [
                "type": "tool_result", "id": "b-1", "toolUseId": "tc-1", "output": "full"
            ] as [String: Any]
        ])
        await hydration.value

        #expect(!store.isBlockHydrated(messageId: "msg-a1", blockId: "b-1"))
        #expect(store.hydratingBlockKeys.isEmpty)
        expectAgentBTranscriptIntact(store)
    }

    @Test func staleSubscribeReplyAfterRebindKeepsNewAgentChannel() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.unsubscribe"] = [String: Any]()

        fake.pendingMethods = ["chat.subscribe"]
        let subscribeA = Task { await store.subscribeLiveChat(agentId: "agent-a") }
        while !fake.didCallMethod("chat.subscribe") {
            await Task.yield()
        }

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

// swiftlint:enable no_magic_numbers
