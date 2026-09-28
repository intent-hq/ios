import Foundation
@testable import Intent
import Testing

extension ConversationStartupBudgetTests {
    @Test(arguments: [10, 10_000])
    func matchedVisibleChildrenKeepWorkspaceSizeOutOfPayloads(unrelated: Int) async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        fixture.startup.unrelatedAgentCount = unrelated
        fixture.startup.watchedIds = ["child-visible", "child-offscreen"]
        let model = fixture.startup.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        let owner = UUID()
        watched.setVisible("child-visible", visible: true, consumer: owner)
        try await waitUntil("matched visible child detail") { watched.row("child-visible").hasSummary }
        let opened = fixture.connection.traffic()
        #expect(opened.calls("agent.get").count == 2)
        #expect(opened.calls("agent.list").isEmpty)
        #expect(opened.calls("chat.subscribe").count == 1)
        #expect(!watched.row("child-offscreen").hasSummary)
        try ConversationBudgetEvidence.emit("watched-\(unrelated)-open", opened)
        watched.releaseVisibility(consumer: owner)
        try await fixture.stopAndWait()
        try ConversationBudgetEvidence.emit("watched-\(unrelated)-complete", fixture.connection.traffic())
    }

    @Test func restoredDetailTitleAndQuestionRetryIncludeTheirWholeCost() async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        let connection = fixture.connection
        fixture.startup.parentMetadata["pendingQuestionsMessageId"] = "outside-page"
        connection.responseMap["workspace.list"] = ["workspaces": []]
        connection.errorQueueMap["agent.getConversation"] = [RPCFixtureRejection(code: -32_603, message: "temporary seek failure")]
        _ = try await fixture.startup.details.load(agentId: ConversationStartupFixture.parentId)
        let restored = connection.checkpoint
        let workspaceStore = WorkspaceStore(connectionManager: connection)
        await workspaceStore.fetchIfNeeded()
        await workspaceStore.fetchIfNeeded()
        let model = fixture.startup.makeViewModel()
        model.store.markedQuestionRetryDelays = [.milliseconds(1)]
        await model.load()
        try await waitUntil("question retries finish") {
            connection.traffic().calls("agent.getConversation").count == 2
                && connection.traffic().pendingCount == 0
        }
        let traffic = connection.traffic()
        #expect(traffic.calls("agent.get").count == 1)
        #expect(connection.traffic(since: restored).calls("agent.get").isEmpty)
        #expect(traffic.calls("workspace.list").count == 1)
        #expect(traffic.calls("agent.getMessageBlock").isEmpty)
        #expect(traffic.calls("agent.getConversation").allSatisfy { request in
            request.params["limit"] as? Int == 1 && request.params["projection"] as? String == "slim"
                && request.params["aroundMessageId"] as? String == "outside-page"
        })
        try ConversationBudgetEvidence.emit("restored-title-question-open", traffic)
        try await fixture.stopAndWait()
        try ConversationBudgetEvidence.emit("restored-title-question-complete", connection.traffic())
    }

    @Test func matchedReconnectIncludesNewRegistrationsAndAllSideSeeds() async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        await fixture.primeCatalogs()
        let model = fixture.startup.makeViewModel()
        await model.load()
        await model.loadModelCatalogIfNeeded()
        let connection = fixture.connection
        connection.releaseConnectionStateDelivery()
        let start = connection.checkpoint
        connection.simulateDisconnect()
        connection.simulateConnect()
        connection.simulateConnect()
        try await waitUntil("matched reconnect settled") {
            let traffic = connection.traffic(since: start)
            return traffic.calls("chat.subscribe").count == 1 && traffic.calls("agent.getQueue").count == 1
                && traffic.calls("hook.list").count == 1 && traffic.calls("prMonitor.list").count == 1
                && fixture.startup.options.specialistCatalog.isFresh
                && fixture.startup.options.modelCatalog(for: "auggie").isFresh && traffic.pendingCount == 0
        }
        await model.loadModelCatalogIfNeeded()
        let reconnect = connection.traffic(since: start)
        #expect(reconnect.requests.count == 10)
        #expect(reconnect.calls("chat.unsubscribe").isEmpty)
        #expect(reconnect.calls("events.unsubscribe").isEmpty)
        #expect(reconnect.requests.allSatisfy { $0.started.connectionGeneration == 2 })
        let ids = connection.traffic().calls("chat.subscribe").compactMap { request -> String? in
            guard let data = request.responseJSON,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = value["result"] as? [String: Any] else { return nil }
            return result["subscriptionId"] as? String
        }
        #expect(Set(ids).count == 2)
        try ConversationBudgetEvidence.emit("reconnect-recovery", reconnect)
        fixture.startup.stop()
        try await waitUntil("new epoch cleanup") {
            let traffic = connection.traffic()
            return traffic.calls("chat.unsubscribe").count == 1 && traffic.calls("events.unsubscribe").count == 2
                && traffic.pendingCount == 0
        }
        try ConversationBudgetEvidence.emit("reconnect-complete", connection.traffic())
    }
}
