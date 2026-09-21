import Foundation
@testable import Intent
import Testing

// swiftlint:disable file_length
// Extracted wire fixtures intentionally mirror the daemon payloads inline.
// swiftlint:disable multiline_arguments multiline_call_arguments multiline_literal_brackets no_magic_numbers

extension ConversationStoreLiveStateTests {
    /// Agent B's seq-0 snapshot row.
    private var agentBRow: [String: Any] {
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

    private func expectAgentBTranscriptIntact(_ store: ConversationStore) {
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
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-a"])
        // B's snapshot settled the shared loading flag A raised.
        #expect(store.isLoading == false)
    }

    /// A stale registration for agent A must not finish agent B's own
    /// in-flight initial load: `isLoading` stays up, and the firehose events
    /// buffered meanwhile are released — not replayed — when B's snapshot,
    /// the authoritative transcript, lands.
    @Test func staleSubscribeDoesNotFinishNewAgentInFlightInitialLoad() async {
        let (store, fake) = makeStore()
        let subscribeA = await startPendingSubscribeForAgentA(store, fake)

        // Rebind to B via its own pending registration (messages stay empty).
        let subscribeB = Task { await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1") }
        while fake.paramsForMethod("chat.subscribe").count < 2 {
            await Task.yield()
        }
        #expect(store.isLoading)

        // Buffered while loading; applying it would flip isStreaming.
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:stream:activity",
                      "data": ["agentId": "agent-b"]] as [String: Any]
        ])
        #expect(store.isStreaming == false)

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-a"])
        await subscribeA.value

        #expect(store.isLoading, "stale A must not clear B's in-flight initial load")
        #expect(store.isStreaming == false, "the buffer must wait for B's snapshot")
        #expect(store.messages.isEmpty)

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-chat-123"])
        await subscribeB.value
        #expect(store.isLoading, "an acked registration still awaits its seq-0 snapshot")
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [agentBRow]))

        #expect(store.isLoading == false)
        #expect(store.isStreaming == false, "the idle snapshot is authoritative over the buffered activity")
        #expect(store.streamEventBuffer.isEmpty)
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
        #expect(store.isStreaming == false, "the buffer must wait for B's snapshot")
        #expect(store.liveTranscript.chatChannelActive, "A's failure must not tear down B's channel")

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-chat-123"])
        await subscribeB.value
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [agentBRow]))

        #expect(store.isLoading == false)
        #expect(store.isStreaming == false)
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
    /// the same window must not (concurrent same-agent fetches keep merging).
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

// MARK: - Registration generation (recovery and replies outliving their registration)

extension ConversationStoreLiveStateTests {
    /// Agent A's seq-0 snapshot row.
    private var agentARow: [String: Any] {
        [
            "id": "msg-a1", "role": "user",
            "contentBlocks": [["type": "text", "id": "msg-a1:0", "text": "Stale A"]],
            "timestamp": "2026-06-27T01:00:00.000Z"
        ]
    }

    /// Acks agent A's registration without a snapshot; its timeout fires and
    /// the retry parks releasing `sub-a` (`chat.unsubscribe` suspended).
    private func parkRetryOfAgentAInUnsubscribe() async throws -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.snapshotTimeout = .milliseconds(20)
        store.liveTranscript.initialRetryDelay = .milliseconds(10)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-a"]
        fake.pendingMethods = ["chat.unsubscribe"]

        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(store.isLoading)
        return (store, fake)
    }

    /// A retry parked in the release of agent A's stale registration must
    /// not revive A once the transcript was rebound to agent B meanwhile.
    @Test func retryParkedInUnsubscribeDoesNotReviveAgentAAfterRebind() async throws {
        let (store, fake) = try await parkRetryOfAgentAInUnsubscribe()

        fake.stubChatSnapshot(subscriptionId: "sub-b", messages: [agentBRow])
        await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1")
        expectAgentBTranscriptIntact(store)

        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await expectNever("a revived registration for agent A") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
        #expect(fake.paramsForMethod("chat.subscribe").compactMap { $0["agentId"] as? String } == ["agent-a", "agent-b"])
        #expect(store.liveTranscript.agentId == "agent-b")
        #expect(fake.hasSubscriptionHandler(id: "sub-b"))
        expectAgentBTranscriptIntact(store)
        #expect(store.isLoading == false)
    }

    /// Same retry, but the store was `reset()` while it waited: nothing may
    /// re-register or restore the old binding's loading state.
    @Test func retryParkedInUnsubscribeDoesNotReviveTheBindingAfterReset() async throws {
        let (store, fake) = try await parkRetryOfAgentAInUnsubscribe()

        store.reset()
        #expect(store.isLoading == false)

        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await expectNever("a registration revived after reset") {
            fake.paramsForMethod("chat.subscribe").count > 1
        }
        #expect(store.liveTranscript.agentId == nil)
        #expect(store.isLoading == false)
        #expect(!store.liveTranscript.chatChannelActive)
        #expect(store.messages.isEmpty)
    }

    /// Agent A's acked registration is detached the moment agent B registers:
    /// A's late snapshot reaches neither the handler nor the push gate, so it
    /// cannot seed B's channel or settle B's in-flight initial load.
    @Test func lateSnapshotOfPreviousRegistrationDoesNotSeedThePendingOne() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-a"]
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(fake.hasSubscriptionHandler(id: "sub-a"))

        fake.pendingMethods = ["chat.subscribe"]
        let subscribeB = Task { await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("chat.subscribe")
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"), "B's registration detaches A's channel")

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-a", kind: .snapshot, seq: 0, snapshot: [agentARow], delta: nil
        ))
        var stalePush = snapshotParams(messages: [agentARow])
        stalePush["subscriptionId"] = "sub-a"
        store.handleStreamEvent("subscription.push", params: stalePush)
        #expect(store.messages.isEmpty)
        #expect(store.isLoading, "A's late snapshot must not settle B's initial load")
        #expect(store.liveTranscript.chatSeeded == false)

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-b"])
        await subscribeB.value
        #expect(store.liveTranscript.snapshotTimeoutTask != nil, "B's own snapshot is still awaited")

        var livePush = snapshotParams(messages: [agentBRow])
        livePush["subscriptionId"] = "sub-b"
        store.handleStreamEvent("subscription.push", params: livePush)
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.isLoading == false)
    }

    /// Parks one same-agent registration, then resolves a newer one for the
    /// same agent first (with its snapshot). Returns the parked task.
    private func startSupersededSameAgentRegistration(
        _ store: ConversationStore,
        _ fake: FakeConnectionManager
    ) async throws -> Task<Void, Never> {
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        fake.pendingMethods = ["chat.subscribe"]
        let first = Task { await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("chat.subscribe")

        fake.pendingMethods = []
        fake.stubChatSnapshot(subscriptionId: "sub-2", messages: [agentBRow])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.liveTranscript.chatLive)
        return first
    }

    /// An older same-agent ack that lands after the newer registration took
    /// the channel is an orphan: released, never registered.
    @Test func olderSameAgentAckAfterTheNewerDoesNotReplaceTheLiveChannel() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        let first = try await startSupersededSameAgentRegistration(store, fake)

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-1"])
        await first.value

        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
        #expect(store.liveTranscript.chatSubscriptionId == "sub-2")
        #expect(store.liveTranscript.chatLive)
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-1"])
    }

    /// An older same-agent failure that lands after the newer registration
    /// took the channel must neither clear it nor schedule a retry.
    @Test func olderSameAgentFailureAfterTheNewerDoesNotClearTheLiveChannel() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        let first = try await startSupersededSameAgentRegistration(store, fake)

        fake.failPending("chat.subscribe", with: NSError(domain: "WebSocket", code: -32_000))
        await first.value

        #expect(store.liveTranscript.chatChannelActive)
        #expect(store.liveTranscript.chatLive)
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(store.liveTranscript.retryTask == nil, "a superseded registration schedules no retry")
        #expect(fake.paramsForMethod("chat.unsubscribe").isEmpty)
    }

    private func gapDelta(subscriptionId: String, seq: Int) -> SubscriptionPush {
        SubscriptionPush(
            subscriptionId: subscriptionId,
            kind: .delta,
            seq: seq,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        )
    }

    /// Seeds agent A, then parks A's gap recovery in the release of `sub-a`
    /// (`chat.unsubscribe` suspended).
    private func parkGapRecoveryOfAgentAInUnsubscribe() async throws -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [agentARow])
        fake.pendingMethods = ["chat.unsubscribe"]

        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store.messages.map(\.id) == ["msg-a1"])
        fake.deliverSubscriptionPush(gapDelta(subscriptionId: "sub-a", seq: 5))
        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(store.liveTranscript.resnapshotInProgress)
        return (store, fake)
    }

    /// Recovery is owned per registration: agent A's gap recovery, parked in
    /// the release of `sub-a`, neither blocks agent B's own gap recovery nor
    /// touches B once A's release finishes.
    @Test func gapOfTheNewBindingRecoversWhileTheOldBindingsRecoveryIsParked() async throws {
        let (store, fake) = try await parkGapRecoveryOfAgentAInUnsubscribe()

        fake.stubChatSnapshot(subscriptionId: "sub-b", messages: [agentBRow])
        await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1")
        expectAgentBTranscriptIntact(store)
        #expect(!store.liveTranscript.resnapshotInProgress, "A's recovery does not mark B's registration")

        // B's gap must open B's own recovery: the release of sub-b parks
        // behind A's still-suspended release.
        fake.deliverSubscriptionPush(gapDelta(subscriptionId: "sub-b", seq: 7))
        try await fake.waitForPendingRequests("chat.unsubscribe", count: 2)
        #expect(store.liveTranscript.resnapshotInProgress)
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-a", "sub-b"])
        expectAgentBTranscriptIntact(store)

        // A's release completes first: its recovery is superseded and does nothing.
        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await expectNever("a registration opened by agent A's superseded recovery") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
        #expect(store.liveTranscript.resnapshotInProgress, "B's recovery still owns the channel")

        // B's release completes: exactly one replacement registration for B follows.
        fake.stubChatSnapshot(subscriptionId: "sub-b2", messages: [agentBRow])
        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await waitUntil("agent B's replacement registration") { fake.hasSubscriptionHandler(id: "sub-b2") }
        #expect(fake.paramsForMethod("chat.subscribe").compactMap { $0["agentId"] as? String } == ["agent-a", "agent-b", "agent-b"])
        #expect(!store.liveTranscript.resnapshotInProgress)
        #expect(store.liveTranscript.chatLive)
        expectAgentBTranscriptIntact(store)
        try await expectNever("a further replacement registration") {
            fake.paramsForMethod("chat.subscribe").count > 3
        }
    }

    /// A recovery scheduled for agent A's registration that only runs after
    /// agent B registered must not release, re-register or unseed B.
    @Test func recoveryScheduledBeforeSupersessionDoesNothingWhenItRuns() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [agentARow])
        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        let staleRecovery = store.liveTranscript.registrationGeneration

        fake.stubChatSnapshot(subscriptionId: "sub-b", messages: [agentBRow])
        await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1")
        expectAgentBTranscriptIntact(store)
        #expect(store.liveTranscript.chatLive)

        await store.liveTranscript.resnapshot(for: staleRecovery)

        #expect(store.liveTranscript.chatLive, "the stale recovery does not unseed B's channel")
        #expect(store.liveTranscript.chatSeeded)
        #expect(fake.hasSubscriptionHandler(id: "sub-b"))
        #expect(store.liveTranscript.chatSubscriptionId == "sub-b")
        #expect(fake.paramsForMethod("chat.unsubscribe").isEmpty, "B's registration is not released")
        #expect(fake.paramsForMethod("chat.subscribe").count == 2)
        expectAgentBTranscriptIntact(store)
    }
}

// swiftlint:enable multiline_arguments multiline_call_arguments multiline_literal_brackets no_magic_numbers
