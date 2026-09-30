import Foundation
@testable import Intent
import Testing

// MARK: - Turn boundaries landing during the initial load

extension ConversationStoreTests {
    @Test func turnBoundaryDuringInitialLoadRefreshesTheMarkerWithoutReplay() async throws {
        // Regression (PR #210 review): a turn ending mid-load must still raise
        // the pending-questions marker. There is no stream-event buffer any
        // more: agent:idle / agent:status-changed refresh the marker as they
        // land, one shared raiseOnly agent.get, and the seq-0 snapshot neither
        // replays them nor issues a refresh of its own.
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat"]
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "a",
                "name": "A",
                "metadata": ["pendingQuestionsMessageId": "a1"]
            ] as [String: Any]
        ] as [String: Any]
        let store = ConversationStore(connectionManager: fake)

        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.isLoading)

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:status-changed",
                "data": ["agentId": "a", "status": "idle"]
            ] as [String: Any]
        ])
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:idle", "data": ["agentId": "a"]] as [String: Any]
        ])
        try await waitUntil("the mid-load turn boundaries to refresh the marker") {
            store.pendingQuestionsMessageId == "a1"
        }
        try await waitUntil("coalesced turn-boundary detail read") {
            fake.requestLog.filter { $0.method == "agent.get" }.count == 1
        }
        #expect(store.isLoading, "the marker refresh does not finish the initial load")

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-chat",
            seq: 0,
            conversationSnapshot: [],
            metadata: ["agentId": "a"]
        ))
        #expect(!store.isLoading)
        // The snapshot is the transcript; it neither replays the boundaries
        // nor adds a refresh of its own.
        try await expectNever("an agent.get issued by the snapshot") {
            fake.requestLog.filter { $0.method == "agent.get" }.count > 1
        }
        #expect(
            store.pendingQuestionsMessageId == "a1",
            "the marker raised mid-load survives the snapshot"
        )
    }

    /// Binds agent "a" with the seq-0 snapshot still pending, fires the turn
    /// boundary `eventType` for it, and holds the `agent.get` it schedules.
    private func bindWithHeldBoundaryRefresh(
        _ eventType: String
    ) async throws -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat"]
        fake.pendingMethods.insert("agent.get")
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        #expect(store.isLoading)

        var data: [String: Any] = ["agentId": "a"]
        if eventType == "agent:status-changed" { data["status"] = "responding" }
        store.handleStreamEvent("events.event", params: [
            "event": ["type": eventType, "data": data] as [String: Any]
        ])
        try await fake.waitForPendingRequests("agent.get")
        return (store, fake)
    }

    private func deliverIdleSnapshot(_ fake: FakeConnectionManager) {
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-chat",
            seq: 0,
            conversationSnapshot: [],
            metadata: ["agentId": "a", "turnInFlight": false]
        ))
    }

    /// An `agent.get` reply for a turn that was still in flight when it was read.
    private func liveTurnReply(pendingQuestionsMessageId: String) -> [String: Any] {
        [
            "agent": [
                "id": "a",
                "name": "A",
                "isStreaming": true,
                "turnInFlight": true,
                "metadata": ["pendingQuestionsMessageId": pendingQuestionsMessageId]
            ] as [String: Any]
        ]
    }

    @Test(arguments: ["agent:idle", "agent:status-changed"])
    func staleBoundaryReplyYieldsStreamingToTheSnapshotItRaced(eventType: String) async throws {
        // A boundary landing mid-load reads agent.get at once. If the seq-0
        // snapshot applies while that read is in flight, the snapshot is the
        // authoritative streaming state: a reply that still says the turn is
        // live must not re-raise the flag (no terminal delta is owed for a
        // turn the snapshot already saw finished). The markers still apply.
        let (store, fake) = try await bindWithHeldBoundaryRefresh(eventType)

        deliverIdleSnapshot(fake)
        #expect(!store.isLoading)
        #expect(!store.isStreaming, "the idle snapshot settles the flag")

        fake.resolvePending("agent.get", with: liveTurnReply(pendingQuestionsMessageId: "a1"))
        try await waitUntil("the stale reply to apply its marker") {
            store.pendingQuestionsMessageId == "a1"
        }
        #expect(!store.isStreaming, "a reply that predates the snapshot must not re-raise streaming")
        try await expectNever("streaming re-raised by the stale \(eventType) reply") {
            store.isStreaming
        }
    }

    @Test func boundaryReplyBeforeTheSnapshotStillRaisesAndIsSettledByIt() async throws {
        // The complement: a reply landing before the snapshot is the freshest
        // signal and raises the flag; the snapshot then settles it.
        let (store, fake) = try await bindWithHeldBoundaryRefresh("agent:idle")
        #expect(!store.isStreaming)

        fake.resolvePending("agent.get", with: liveTurnReply(pendingQuestionsMessageId: "a1"))
        try await waitUntil("the reply to raise streaming before the snapshot") {
            store.isStreaming
        }
        #expect(store.pendingQuestionsMessageId == "a1")
        #expect(store.isLoading, "the reply does not finish the initial load")

        deliverIdleSnapshot(fake)
        #expect(!store.isLoading)
        #expect(!store.isStreaming, "the snapshot settles the flag the reply raised")
        #expect(store.pendingQuestionsMessageId == "a1", "the marker survives the snapshot")
    }
}
