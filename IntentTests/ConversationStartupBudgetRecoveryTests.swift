import Foundation
@testable import Intent
import Testing

extension ConversationStartupBudgetTests {
    @Test(arguments: [false, true])
    func lostSnapshotAndRejectedRegistrationIncludeRecoveryBytes(rejected: Bool) async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        let connection = fixture.connection
        let model = fixture.startup.makeViewModel()
        model.store.liveTranscript.initialRetryDelay = .milliseconds(1)
        if rejected {
            connection.errorQueueMap["chat.subscribe"] = [RPCFixtureRejection(code: -32_603, message: "temporary registration failure")]
        } else {
            connection.pendingMethods = ["chat.subscribe"]
            model.store.liveTranscript.snapshotTimeout = .milliseconds(10)
        }
        let load = Task { await model.load() }
        defer { load.cancel() }
        if !rejected {
            try await connection.waitForPendingRequests("chat.subscribe")
            connection.pendingMethods = []
            connection.resolvePending("chat.subscribe", with: ["subscriptionId": "budget-lost-snapshot"])
        }
        await load.value
        try await waitUntil("registration recovery and complete side state") {
            let traffic = connection.traffic()
            return model.messages.count == 1 && traffic.calls("chat.subscribe").count == 2
                && traffic.calls("hook.list").count == 1 && traffic.calls("prMonitor.list").count == 1
                && traffic.pendingCount == 0
        }
        let traffic = connection.traffic()
        #expect(traffic.calls("chat.subscribe").allSatisfy { $0.params["deltaEncoding"] as? String == "incremental" })
        #expect(traffic.requests.count == (rejected ? 9 : 10))
        let name = rejected ? "rejected-registration" : "missing-snapshot"
        try ConversationBudgetEvidence.emit(name + "-open", traffic)
        try await fixture.stopAndWait()
        try ConversationBudgetEvidence.emit(name + "-complete", connection.traffic())
    }

    @Test func lateAckAfterCloseIncludesOrphanCleanupAndReceivedFrame() async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        let connection = fixture.connection
        connection.pendingMethods = ["chat.subscribe"]
        let model = fixture.startup.makeViewModel()
        let load = Task { await model.load() }
        defer { load.cancel() }
        try await connection.waitForPendingRequests("chat.subscribe")
        try await waitUntil("side state settled before closing") {
            let traffic = connection.traffic()
            return traffic.calls("hook.list").count == 1 && traffic.calls("prMonitor.list").count == 1
                && traffic.pendingCount == 1
        }
        model.teardownLiveStores()
        connection.resolvePending("chat.subscribe", with: ["subscriptionId": "budget-late-ack"])
        await load.value
        try await waitUntil("late registration released") {
            connection.traffic().calls("chat.unsubscribe").count == 1 && connection.traffic().pendingCount == 0
        }
        // An already-sent frame can arrive after close. It costs bytes even
        // though its orphaned registration no longer has a local consumer.
        try connection.deliverNotification(params: [
            "subscriptionId": "budget-late-ack", "kind": "snapshot", "seq": 0,
            "snapshot": [
                "agentId": ConversationStartupFixture.parentId,
                "messages": fixture.messages(ConversationStartupFixture.parentId),
                "totalMessages": 1, "truncated": false, "nextToken": NSNull(),
                "isResponding": false, "turnInFlight": false, "deltaEncoding": "incremental"
            ]
        ])
        #expect(model.store.liveTranscript.chatSubscriptionId == nil)
        #expect(connection.subscriptionHandlerCount == 0)
        try await fixture.stopAndWait()
        #expect(connection.traffic().calls("chat.unsubscribe").first?.params["subscriptionId"] as? String == "budget-late-ack")
        try ConversationBudgetEvidence.emit("late-ack-complete", connection.traffic())
    }
}
