import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupBudgetTests {
    @Test(arguments: [false, true], [false, true])
    func matchedOpeningIncludesDeferredRepliesAndCleanup(warm: Bool, delayed: Bool) async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        await fixture.primeCatalogs()
        if warm { await fixture.warmWorkspace() }
        let connection = fixture.connection
        let checkpoint = connection.checkpoint
        let name = "\(warm ? "warm" : "cold")-\(delayed ? "barrier" : "immediate")"
        if delayed { connection.pendingMethods = ["agent.get", "agent.getQueue", "agent.getSubscriptions", "events.subscribe"] }
        let model = fixture.startup.makeViewModel()
        let load = Task { await model.load() }
        defer { load.cancel() }
        if delayed {
            try await connection.waitForPendingRequests("agent.getQueue")
            try await connection.waitForPendingRequests("agent.getSubscriptions")
            try await waitUntil("matched snapshot before delayed side responses") { !model.isLoading && model.messages.count == 1 }
            #expect(connection.traffic(since: checkpoint).calls("agent.get").first?.completed == nil)
            try ConversationBudgetEvidence.emit(name + "-at-snapshot", connection.traffic(since: checkpoint))
            if !warm {
                try await connection.waitForPendingRequests("events.subscribe", count: 2)
                connection.resolvePending("events.subscribe", with: ["subscriptionId": "delayed-hook-101"])
                connection.resolvePending("events.subscribe", with: ["subscriptionId": "delayed-monitor-102"])
            }
            connection.resolvePending("agent.get", with: ["agent": fixture.startup.agent(ConversationStartupFixture.parentId)])
            connection.resolvePending("agent.getQueue", with: ["queue": []])
            connection.resolvePending("agent.getSubscriptions", with: fixture.startup.subscriptions())
            connection.pendingMethods = []
        }
        await load.value
        await model.loadModelCatalogIfNeeded()
        let opened = connection.traffic(since: checkpoint)
        #expect(opened.requests.count == (warm ? 4 : 8))
        #expect(opened.pendingCount == 0 && opened.failures.isEmpty)
        #expect(opened.calls("models.list").isEmpty && opened.calls("specialist.list").isEmpty)
        #expect(model.messages.first?.contentBlocks.first?.resolvedText == "Ready café 🦊 0")
        try ConversationBudgetEvidence.emit(name + "-open", opened)
        let cleanup = connection.checkpoint
        try await fixture.stopAndWait()
        try ConversationBudgetEvidence.emit(name + "-cleanup", connection.traffic(since: cleanup))
        try ConversationBudgetEvidence.emit(name + "-complete", connection.traffic(since: checkpoint))
        try ConversationBudgetEvidence.emit(name + "-including-setup", connection.traffic())
    }

    @Test func fiftySlimRowsAndDeferredCatalogsStayInCompleteAccounting() async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        fixture.rows = 50
        fixture.largeBlocks = true
        fixture.startup.providerId = "auggie"
        fixture.startup.modelId = "fixture-model"
        fixture.startup.parentMetadata["specialist"] = "fixture-specialist"
        let model = fixture.startup.makeViewModel()
        await model.load()
        await model.loadModelCatalogIfNeeded()
        let opened = fixture.connection.traffic()
        #expect(model.messages.count == 50)
        #expect(opened.requests.count == 10)
        #expect(opened.calls("agent.getMessageBlock").isEmpty && opened.calls("agent.getSession").isEmpty)
        #expect(opened.calls("agent.getConversation").isEmpty)
        let chat = try #require(opened.calls("chat.subscribe").first)
        #expect(chat.params["limit"] as? Int == 50)
        #expect(chat.params["projection"] as? String == "slim")
        #expect(opened.notificationBytes < 512 * 1024)
        #expect(model.messages.allSatisfy { $0.contentBlocks.count == 3 })
        try ConversationBudgetEvidence.emit("slim-50-catalogs-open", opened)
        try await fixture.stopAndWait()
        try ConversationBudgetEvidence.emit("slim-50-catalogs-complete", fixture.connection.traffic())
    }

    @Test func receivedCompatibilityErrorAndRetryAreBothCounted() async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        let rejection = RPCFixtureRejection(code: -32_602, message: "unknown field `deltaEncoding`, expected `agentId` (-32602)")
        fixture.connection.errorQueueMap["chat.subscribe"] = [rejection]
        let model = fixture.startup.makeViewModel()
        await model.load()
        let opened = fixture.connection.traffic()
        let attempts = opened.calls("chat.subscribe")
        #expect(attempts.count == 2)
        #expect(try attempts.first?.responseJSON == RPCFixtureJSON.encode(rejection.json))
        #expect(attempts.last?.params["deltaEncoding"] == nil)
        #expect(!model.store.liveTranscript.incrementalDeltas)
        #expect(!model.isLoading && model.messages.count == 1)
        #expect(opened.requests.count == 9 && opened.pendingCount == 0)
        try ConversationBudgetEvidence.emit("compatibility-open", opened)
        try await fixture.stopAndWait()
        try ConversationBudgetEvidence.emit("compatibility-complete", fixture.connection.traffic())
    }
}
