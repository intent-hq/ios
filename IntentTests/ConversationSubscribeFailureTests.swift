import Foundation
@testable import Intent
import Testing

/// #765: a `chat.subscribe` the daemon never acknowledges must end in a
/// terminal failed stage instead of retrying forever.
@MainActor
struct ConversationSubscribeFailureTests {
    private static let timedOut = NSError(
        domain: "WebSocket", code: -2, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
    )

    private func neverAckingTranscript() -> (FakeConnectionManager, ConversationLiveTranscript) {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        fake.pendingMethods = ["chat.subscribe"]
        let live = ConversationLiveTranscript(connectionManager: fake)
        live.initialRetryDelay = .milliseconds(10)
        live.maxSubscriptionAttempts = 3
        return (fake, live)
    }

    /// Times out every in-flight `chat.subscribe` until `count` were sent.
    private func timeOutRequests(_ fake: FakeConnectionManager, through count: Int) async throws {
        for sent in 1...count {
            try await fake.waitForRequests("chat.subscribe", count: sent)
            try await fake.waitForPendingRequests("chat.subscribe")
            fake.failPending("chat.subscribe", with: Self.timedOut)
        }
    }

    private func row(_ id: String) -> [String: Any] {
        [
            "id": id,
            "role": "user",
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": "Hello"]],
            "timestamp": "2026-09-18T00:00:00Z"
        ]
    }

    @Test func defaultBoundSettlesWithinAMinuteOfUnackedRequests() {
        let attempts = ConversationLiveTranscript.defaultMaxSubscriptionAttempts
        let backoff = (0..<(attempts - 1)).reduce(Duration.zero) { total, retry in
            total + min(ConversationLiveTranscript.defaultInitialRetryDelay * (1 << retry), ConversationLiveTranscript.defaultMaxRetryDelay)
        }
        let worstCase = Duration.seconds(ConnectionManager.defaultRequestTimeout) * attempts + backoff
        #expect(attempts > 1)
        #expect(worstCase <= .seconds(60))
    }

    @Test func neverAckedSubscribeSettlesOnFailedAfterBoundedAttempts() async throws {
        let (fake, live) = neverAckingTranscript()
        let load = Task { await live.subscribe(agentId: "agent") }

        try await timeOutRequests(fake, through: 3)
        try await waitUntil("the bounded cycle to give up") { live.loadingStage == .failed }
        await load.value

        #expect(live.isLoading, "the failed stage replaces the loading view, not the transcript")
        #expect(live.retryTask == nil)
        #expect(live.snapshotWaiters.isEmpty)
        try await expectNever("another chat.subscribe after the bound", within: .milliseconds(150)) {
            fake.paramsForMethod("chat.subscribe").count > 3
        }
        #expect(live.loadingStage == .failed)
        live.reset()
    }

    @Test func retryFromFailedStartsAFreshBoundedCycle() async throws {
        let (fake, live) = neverAckingTranscript()
        let load = Task { await live.subscribe(agentId: "agent") }
        try await timeOutRequests(fake, through: 3)
        try await waitUntil("the bounded cycle to give up") { live.loadingStage == .failed }
        await load.value

        let retry = Task { await live.retryNow() }
        try await fake.waitForRequests("chat.subscribe", count: 4)
        try await fake.waitForPendingRequests("chat.subscribe")
        #expect(live.loadingStage == .requesting, "a manual retry starts over at attempt 1")

        fake.failPending("chat.subscribe", with: Self.timedOut)
        await retry.value
        #expect(live.loadingStage == .retrying(attempt: 2), "the fresh cycle retries again instead of failing at once")

        fake.stubChatSnapshot(subscriptionId: "sub-1", messages: [row("msg-1")])
        try await fake.waitForPendingRequests("chat.subscribe")
        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-1"])
        try await waitUntil("the retried registration's snapshot") { live.messages.map(\.id) == ["msg-1"] }
        #expect(!live.isLoading)
        #expect(live.loadingStage == .idle)
        #expect(fake.paramsForMethod("chat.subscribe").count == 5)
        live.reset()
    }

    /// The daemon acks but its snapshot is late: after the cycle fails, the
    /// still-registered subscription's snapshot settles the load without a
    /// further registration.
    @Test func lateSnapshotAfterFailureRecoversWithoutDuplicateSubscriptions() async throws {
        let (fake, live) = neverAckingTranscript()
        live.maxSubscriptionAttempts = 2
        live.snapshotTimeout = .milliseconds(20)
        fake.responseMap["chat.unsubscribe"] = [String: Any]()
        let load = Task { await live.subscribe(agentId: "agent") }

        for (index, subscriptionId) in ["sub-1", "sub-2"].enumerated() {
            try await fake.waitForRequests("chat.subscribe", count: index + 1)
            try await fake.waitForPendingRequests("chat.subscribe")
            fake.resolvePending("chat.subscribe", with: ["subscriptionId": subscriptionId])
        }
        try await waitUntil("the bounded cycle to give up") { live.loadingStage == .failed }
        await load.value
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-2", kind: .snapshot, seq: 0, snapshot: [row("msg-1")], delta: nil
        ))

        #expect(live.messages.map(\.id) == ["msg-1"])
        #expect(!live.isLoading)
        #expect(live.loadingStage == .idle)
        try await expectNever("a registration after the late snapshot recovered") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-1"])
        live.reset()
    }
}
