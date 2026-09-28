import Foundation
@testable import Intent
import Testing

extension ConversationStartupRPCTests {
    @Test func completeCatalogReconnectIncludesDeferredConsumerReads() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        configureCatalogs(fixture)
        let connection = fixture.connection
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        await viewModel.loadModelCatalogIfNeeded()
        connection.releaseConnectionStateDelivery()
        let checkpoint = connection.checkpoint
        connection.simulateDisconnect()
        connection.simulateConnect()
        connection.simulateConnect()
        try await waitUntil("reconnect bootstrap and catalogs settled") {
            connection.traffic(since: checkpoint).calls("chat.subscribe").count == 1
                && fixture.options.specialistCatalog.isFresh
                && fixture.options.modelCatalog(for: "auggie").isFresh
                && connection.traffic().pendingCount == 0
        }
        // This is the actual separate SwiftUI catalog task, included even if
        // its scheduling happens after every fast reconnect response.
        await viewModel.loadModelCatalogIfNeeded()
        let traffic = connection.traffic(since: checkpoint)
        printCatalogLedger("full-reconnect-with-deferred-task", traffic)
        #expect(traffic.calls("specialist.list").count == 1)
        #expect(traffic.calls("models.list").count == 1)
        #expect(traffic.calls("agent.get").count == 1)
        #expect(traffic.calls("host.providerAuthStatus").isEmpty)
        #expect(traffic.calls("providers.catalog").isEmpty)
        #expect(viewModel.specialistName == "Fixture specialist")
        #expect(viewModel.currentModelDisplayName == "Fixture model")
    }

    @Test func completeCatalogStartupAndCleanupLedger() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        configureCatalogs(fixture)
        let connection = fixture.connection
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        await viewModel.loadModelCatalogIfNeeded()
        printCatalogLedger("startup-cold", connection.traffic())
        #expect(connection.traffic().requests.count == 10)
        #expect(connection.traffic().totalBytes == 2402)
        let retained = connection.checkpoint
        await viewModel.load()
        await viewModel.loadModelCatalogIfNeeded()
        let other = fixture.makeViewModel()
        await other.load()
        await other.loadModelCatalogIfNeeded()
        #expect(connection.traffic(since: retained).requests.isEmpty)
        printCatalogLedger("retained-and-second-window", connection.traffic(since: retained))

        // A window keeps workspace status warm across conversation switches.
        let window = UUID()
        fixture.session.retainWorkspaceStatus(workspaceId: ConversationStartupFixture.workspaceId, consumer: window)
        await fixture.session.hooksStore.load(workspaceId: ConversationStartupFixture.workspaceId)
        await fixture.session.prMonitorsStore.seed(workspaceId: ConversationStartupFixture.workspaceId)
        viewModel.teardownLiveStores()
        other.teardownLiveStores()
        try await waitUntil("old chat released") { connection.traffic().calls("chat.unsubscribe").count == 1 }
        let warm = connection.checkpoint
        await viewModel.load()
        await viewModel.loadModelCatalogIfNeeded()
        let warmTraffic = connection.traffic(since: warm)
        #expect(warmTraffic.methodCounts == ["chat.subscribe": 1, "agent.get": 1, "agent.getQueue": 1, "agent.getSubscriptions": 1])
        printCatalogLedger("fresh-warm", warmTraffic)
        let refresh = connection.checkpoint
        await viewModel.refreshSelectableModels()
        #expect(connection.traffic(since: refresh).methodCounts == ["models.list": 1])
        printCatalogLedger("explicit-model-picker", connection.traffic(since: refresh))

        let cleanup = connection.checkpoint
        viewModel.teardownLiveStores()
        fixture.session.releaseWorkspaceStatus(workspaceId: ConversationStartupFixture.workspaceId, consumer: window)
        fixture.session.teardown()
        try await waitUntil("all remote catalog-fixture ownership released") {
            connection.traffic(since: cleanup).calls("chat.unsubscribe").count == 1
                && connection.traffic(since: cleanup).calls("events.unsubscribe").count == 2
                && connection.traffic().pendingCount == 0
        }
        printCatalogLedger("startup-cleanup", connection.traffic(since: cleanup))
        printCatalogLedger("startup-lifetime-total", connection.traffic())
    }

    @Test func cancellingOneConversationKeepsOtherCatalogConsumerAlive() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        configureCatalogs(fixture)
        let connection = fixture.connection
        connection.pendingMethods = ["specialist.list"]
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        var returned = false
        let cancelled = Task { await first.load(); returned = true }
        let live = Task { await second.load() }
        defer { cancelled.cancel(); live.cancel() }
        try await waitUntil("both conversation labels") {
            first.currentSpecialistId != nil && second.currentSpecialistId != nil
                && connection.pendingRequestCount("specialist.list") == 1
        }
        cancelled.cancel()
        try await waitUntil("cancelled conversation detached") { returned && first.activeLiveStoreActivation == nil }
        #expect(second.activeLiveStoreActivation != nil)
        connection.resolvePending("specialist.list", with: try #require(connection.responseMap["specialist.list"]))
        await live.value
        await second.loadModelCatalogIfNeeded()
        #expect(second.specialistName == "Fixture specialist")
        #expect(second.currentModelDisplayName == "Fixture model")
        #expect(connection.traffic().calls("specialist.list").count == 1)
        #expect(connection.traffic().calls("chat.unsubscribe").isEmpty)
        printCatalogLedger("concurrent-conversation-cancellation", connection.traffic())
    }

    @Test func specialistAndModelEventsUpdateVisibleLabelsWithoutParentReads() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        configureCatalogs(fixture)
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        await viewModel.loadModelCatalogIfNeeded()
        let connection = fixture.connection
        let checkpoint = connection.checkpoint
        connection.responseMap["specialist.list"] = ["specialists": [["id": "fixture-specialist", "name": "New specialist"]]]
        connection.responseMap["models.list"] = ["models": [["id": "fixture-model", "name": "New model", "provider": "auggie"]]]
        CreationOptionsStoreTests().catalogEvent(connection, type: "settings:changed", paths: ["model.default"])
        try await waitUntil("visible catalog labels updated") {
            viewModel.specialistName == "New specialist" && viewModel.currentModelDisplayName == "New model"
        }
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 1, "models.list": 1])
        printCatalogLedger("visible-settings-refresh", connection.traffic(since: checkpoint))
    }

    @Test func absentProviderUsesAgentModelsOnlyForExplicitPicker() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        let checkpoint = fixture.connection.checkpoint
        await viewModel.loadModelCatalogIfNeeded()
        #expect(fixture.connection.traffic(since: checkpoint).requests.isEmpty)
        fixture.connection.responseMap["agent.getModels"] = ["models": []]
        await viewModel.refreshSelectableModels()
        #expect(fixture.connection.traffic(since: checkpoint).methodCounts == ["agent.getModels": 1])
        printCatalogLedger("explicit-unknown-provider-picker", fixture.connection.traffic(since: checkpoint))
    }
}
