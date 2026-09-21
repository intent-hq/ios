import Foundation
@testable import Intent
import Testing

// Extracted wire fixtures intentionally mirror the daemon payloads inline.
// swiftlint:disable multiline_arguments multiline_call_arguments multiline_literal_brackets no_magic_numbers

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
