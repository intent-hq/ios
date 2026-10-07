import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationRetryNowTests {
    private static let longWait: Duration = .seconds(30)

    /// Manual retry must bypass both a rejected registration's backoff and an
    /// acked registration's snapshot timeout, with only one new subscription.
    @Test(arguments: [false, true])
    func retryNowCancelsPendingRecoveryAndRegistersOnce(awaitingSnapshot: Bool) async throws {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.snapshotTimeout = Self.longWait
        store.liveTranscript.initialRetryDelay = Self.longWait
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        if awaitingSnapshot {
            fake.responseMap["chat.subscribe"] = ["subscriptionId": "old"]
        } else {
            fake.errorMap["chat.subscribe"] = NSError(domain: "WebSocket", code: -32_000)
        }
        await store.subscribeLiveChat(agentId: "agent", workspaceId: "workspace")
        let pendingRecovery = try #require(awaitingSnapshot
            ? store.liveTranscript.snapshotTimeoutTask : store.liveTranscript.retryTask)
        fake.errorMap.removeValue(forKey: "chat.subscribe")
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "new"]

        await store.retryNow()

        #expect(pendingRecovery.isCancelled)
        await pendingRecovery.value
        #expect(fake.paramsForMethod("chat.subscribe").count == 2)
        #expect(fake.paramsForMethod("chat.subscribe").last?["agentId"] as? String == "agent")
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String }
            == (awaitingSnapshot ? ["old"] : []))
        #expect(!fake.hasSubscriptionHandler(id: "old"))
        #expect(fake.hasSubscriptionHandler(id: "new"))
        #expect(store.isLoading)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "new", kind: .snapshot, seq: 0, snapshot: [], delta: nil
        ))
        #expect(!store.isLoading)
        #expect(fake.retryConnectionCallCount == 0)
        store.reset()
    }

    /// The user can leave while release is in flight. Manual retry must not
    /// revive that conversation or disturb the next conversation's channel.
    @Test func retryNowDoesNotReviveConversationAfterRebind() async throws {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        let live = ConversationLiveTranscript(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "old"]
        await live.subscribe(agentId: "old-agent", workspaceId: "workspace")
        fake.pendingMethods = ["chat.unsubscribe"]
        let retry = Task { await live.retryNow() }
        try await fake.waitForPendingRequests("chat.unsubscribe")
        fake.stubChatSnapshot(subscriptionId: "new")
        await live.subscribe(agentId: "new-agent", workspaceId: "workspace")

        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        await retry.value

        #expect(fake.paramsForMethod("chat.subscribe").compactMap { $0["agentId"] as? String } == ["old-agent", "new-agent"])
        #expect(fake.hasSubscriptionHandler(id: "new"))
        #expect(!live.isLoading)
        live.reset()
    }

    @Test(arguments: [ConnectionState.disconnected, .connecting, .reconnecting(attempt: 2)])
    func retryNowRequestsTransportReconnectInsteadOfRegistering(state: ConnectionState) async throws {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        let live = ConversationLiveTranscript(connectionManager: fake)
        fake.errorMap["chat.subscribe"] = NSError(domain: "WebSocket", code: -32_000)
        live.initialRetryDelay = Self.longWait
        await live.subscribe(agentId: "agent")
        let backoff = try #require(live.retryTask)
        fake.connectionState = state

        await live.retryNow()

        #expect(backoff.isCancelled)
        await backoff.value
        #expect(fake.retryConnectionCallCount == 1)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1)
        #expect(live.loadingStage == .connecting)
        live.reset()
    }
}
