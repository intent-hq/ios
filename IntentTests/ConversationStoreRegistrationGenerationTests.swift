import Foundation
@testable import Intent
import Testing

// swiftlint:disable no_magic_numbers

// MARK: - Registration generation (recovery and replies outliving their registration)

extension ConversationStoreLiveStateTests {
    private var agentARow: [String: Any] {
        [
            "id": "msg-a1", "role": "user",
            "contentBlocks": [["type": "text", "id": "msg-a1:0", "text": "Stale A"]],
            "timestamp": "2026-06-27T01:00:00.000Z"
        ]
    }

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

    @Test func gapOfTheNewBindingRecoversWhileTheOldBindingsRecoveryIsParked() async throws {
        let (store, fake) = try await parkGapRecoveryOfAgentAInUnsubscribe()

        fake.stubChatSnapshot(subscriptionId: "sub-b", messages: [agentBRow])
        await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1")
        expectAgentBTranscriptIntact(store)
        #expect(!store.liveTranscript.resnapshotInProgress, "A's recovery does not mark B's registration")

        fake.deliverSubscriptionPush(gapDelta(subscriptionId: "sub-b", seq: 7))
        try await fake.waitForPendingRequests("chat.unsubscribe", count: 2)
        #expect(store.liveTranscript.resnapshotInProgress)
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-a", "sub-b"])
        expectAgentBTranscriptIntact(store)

        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await expectNever("a registration opened by agent A's superseded recovery") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
        #expect(store.liveTranscript.resnapshotInProgress, "B's recovery still owns the channel")

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

    @Test func recoveryScheduledBeforeSupersessionDoesNothingWhenItRuns() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.pendingMethods = ["chat.unsubscribe"]
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

        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(
            fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-a"],
            "only the rebind released A; B's registration is not released"
        )
        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await expectNever("a second release or a registration after A's release resolves") {
            fake.paramsForMethod("chat.unsubscribe").count > 1 || fake.paramsForMethod("chat.subscribe").count > 2
        }
        expectAgentBTranscriptIntact(store)
        #expect(store.liveTranscript.chatLive)
        #expect(fake.hasSubscriptionHandler(id: "sub-b"))
        #expect(store.liveTranscript.chatSubscriptionId == "sub-b")
        #expect(fake.paramsForMethod("chat.subscribe").count == 2)
        expectAgentBTranscriptIntact(store)
    }
}

// MARK: - Releasing the acked registration on unbind (rebind, reset, deinit)

extension ConversationStoreLiveStateTests {
    private func seedAgentAWithUnsubscribeParked() async -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [agentARow])
        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store.messages.map(\.id) == ["msg-a1"])
        #expect(store.liveTranscript.chatSubscriptionId == "sub-a")
        fake.pendingMethods = ["chat.unsubscribe"]
        return (store, fake)
    }

    private func unsubscribedIds(_ fake: FakeConnectionManager) -> [String] {
        fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String }
    }

    private var notConnected: NSError {
        NSError(domain: "WebSocket", code: -4, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
    }

    @Test func resetReleasesTheAckedRegistrationWithoutTouchingTheNextBinding() async throws {
        let (store, fake) = await seedAgentAWithUnsubscribeParked()

        store.reset()
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))
        #expect(store.liveTranscript.chatSubscriptionId == nil)
        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(unsubscribedIds(fake) == ["sub-a"])

        fake.stubChatSnapshot(subscriptionId: "sub-b", messages: [agentBRow])
        await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1")
        expectAgentBTranscriptIntact(store)
        #expect(unsubscribedIds(fake) == ["sub-a"], "B had nothing acked to release")

        fake.failPending("chat.unsubscribe", with: NSError(domain: "WebSocket", code: -32_000))
        try await expectNever("a registration opened by A's failed release") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
        #expect(store.liveTranscript.chatSubscriptionId == "sub-b")
        #expect(store.liveTranscript.chatLive)
        #expect(fake.hasSubscriptionHandler(id: "sub-b"))
        expectAgentBTranscriptIntact(store)
    }

    @Test func rebindReleasesThePreviousRegistrationIndependentlyOfTheNewOne() async throws {
        let (store, fake) = await seedAgentAWithUnsubscribeParked()

        fake.stubChatSnapshot(subscriptionId: "sub-b", messages: [agentBRow])
        await store.subscribeLiveChat(agentId: "agent-b", workspaceId: "ws-1")
        expectAgentBTranscriptIntact(store)
        #expect(store.liveTranscript.chatLive)
        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(unsubscribedIds(fake) == ["sub-a"])
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))
        #expect(fake.hasSubscriptionHandler(id: "sub-b"))

        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await expectNever("a registration opened by A's release") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
        #expect(unsubscribedIds(fake) == ["sub-a"])
        #expect(store.liveTranscript.chatSubscriptionId == "sub-b")
        expectAgentBTranscriptIntact(store)
    }

    @Test func resetOfAPendingRegistrationReleasesOnlyItsLateAck() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        fake.pendingMethods = ["chat.subscribe"]
        let subscribe = Task { await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("chat.subscribe")

        store.reset()
        try await expectNever("a release with nothing acked") { fake.didCallMethod("chat.unsubscribe") }

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-a"])
        await subscribe.value
        #expect(unsubscribedIds(fake) == ["sub-a"])
        try await expectNever("a second release of the late ack") {
            fake.paramsForMethod("chat.unsubscribe").count > 1
        }
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))
        #expect(store.liveTranscript.chatSubscriptionId == nil)
    }

    @Test func resetOfARejectedRegistrationSendsNoUnsubscribe() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.initialRetryDelay = .milliseconds(10)
        fake.errorMap["chat.subscribe"] = NSError(domain: "WebSocket", code: -32_000)
        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store.liveTranscript.retryTask != nil)

        store.reset()
        try await expectNever("a release or retry after reset") {
            fake.didCallMethod("chat.unsubscribe") || fake.paramsForMethod("chat.subscribe").count > 1
        }
    }

    @Test func reconnectDoesNotReleaseTheOutagesRegistration() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["events.subscribe"] = ["subscriptionId": "events-a"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        store.subscribeToStreaming(agentId: "agent-a", workspaceId: "ws-1")
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [agentARow])
        await store.subscribeLiveChat(agentId: "agent-a")
        #expect(store.messages.map(\.id) == ["msg-a1"])

        fake.simulateDisconnect()
        fake.stubChatSnapshot(subscriptionId: "sub-a2", messages: [agentARow, agentBRow])
        fake.simulateConnect()
        try await waitUntil("the reconnect registration's snapshot") { store.messages.map(\.id) == ["msg-a1", "msg-b1"] }
        #expect(fake.hasSubscriptionHandler(id: "sub-a2"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))
        try await expectNever("a release of the outage's registration") { fake.didCallMethod("chat.unsubscribe") }
    }

    @Test func resetWhileDisconnectedDoesNotRetryTheRelease() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [agentARow])
        await store.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store.liveTranscript.chatSubscriptionId == "sub-a")

        fake.simulateDisconnect()
        fake.errorMap["chat.unsubscribe"] = notConnected
        store.reset()
        #expect(store.liveTranscript.chatSubscriptionId == nil)
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))

        try await fake.waitForRequests("chat.unsubscribe")
        try await expectNever("a retry of the failed release or a registration") {
            fake.paramsForMethod("chat.unsubscribe").count > 1 || fake.paramsForMethod("chat.subscribe").count > 1
        }
        #expect(store.liveTranscript.chatSubscriptionId == nil)
        #expect(!store.liveTranscript.chatLive)
    }

    @Test func deinitWhileDisconnectedDoesNotRetryTheRelease() async throws {
        let fake = FakeConnectionManager()
        var store: ConversationStore? = ConversationStore(connectionManager: fake)
        weak var transcript = store?.liveTranscript
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [agentARow])
        await store?.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store?.liveTranscript.chatSubscriptionId == "sub-a")

        fake.simulateDisconnect()
        fake.errorMap["chat.unsubscribe"] = notConnected
        store = nil
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))

        try await fake.waitForRequests("chat.unsubscribe")
        #expect(transcript == nil)
        try await expectNever("a retry of the failed release or a registration") {
            fake.paramsForMethod("chat.unsubscribe").count > 1 || fake.paramsForMethod("chat.subscribe").count > 1
        }
        #expect(fake.subscriptionHandlerCount == 0)
    }

    @Test func deinitReleasesTheAckedRegistration() async throws {
        let fake = FakeConnectionManager()
        var store: ConversationStore? = ConversationStore(connectionManager: fake)
        weak var transcript = store?.liveTranscript
        fake.stubChatSnapshot(subscriptionId: "sub-a", messages: [agentARow])
        await store?.subscribeLiveChat(agentId: "agent-a", workspaceId: "ws-1")
        #expect(store?.liveTranscript.chatSubscriptionId == "sub-a")
        fake.pendingMethods = ["chat.unsubscribe"]

        store = nil
        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(unsubscribedIds(fake) == ["sub-a"])
        #expect(!fake.hasSubscriptionHandler(id: "sub-a"))
        #expect(transcript == nil, "the parked release does not retain the transcript")

        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await expectNever("a registration opened by the release") { fake.paramsForMethod("chat.subscribe").count > 1 }
    }
}

// swiftlint:enable no_magic_numbers
