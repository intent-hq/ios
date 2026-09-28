import Foundation
@testable import Intent
import Testing

extension ConversationStartupRPCTests {
    @Test func warmCatalogConsumersAddNoReads() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        configureCatalogs(fixture)
        await fixture.options.loadIfNeeded()
        await fixture.options.loadModelsIfNeeded(providerId: "auggie")
        let checkpoint = fixture.connection.checkpoint
        let first = fixture.makeViewModel()
        await first.load()
        await first.loadModelCatalogIfNeeded()
        let second = fixture.makeViewModel()
        await second.load()
        await second.loadModelCatalogIfNeeded()
        try await expectNever("warm catalog read") {
            fixture.connection.traffic(since: checkpoint).requests.contains { request in
                ["specialist.list", "models.list", "host.providerAuthStatus", "providers.catalog"].contains(request.method)
            }
        }
        #expect(first.specialistName == "Fixture specialist")
        #expect(second.currentModelDisplayName == "Fixture model")
    }

    @Test func concurrentLabelConsumersShareEachColdCatalog() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        configureCatalogs(fixture)
        let connection = fixture.connection
        connection.pendingMethods = ["specialist.list", "models.list"]
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        let firstLoad = Task { await first.load(); await first.loadModelCatalogIfNeeded() }
        let secondLoad = Task { await second.load(); await second.loadModelCatalogIfNeeded() }
        defer { firstLoad.cancel(); secondLoad.cancel() }
        try await waitUntil("both label consumers") {
            first.currentProviderId == "auggie" && second.currentProviderId == "auggie"
                && connection.pendingRequestCount("specialist.list") > 0
        }
        // Release all recorded requests so the pre-fix duplicate produces a
        // count failure rather than an orphaned fake continuation.
        connection.pendingMethods.remove("specialist.list")
        while connection.pendingRequestCount("specialist.list") > 0 {
            connection.resolvePending("specialist.list", with: try #require(connection.responseMap["specialist.list"]))
        }
        try await connection.waitForPendingRequests("models.list")
        connection.pendingMethods.remove("models.list")
        while connection.pendingRequestCount("models.list") > 0 {
            connection.resolvePending("models.list", with: try #require(connection.responseMap["models.list"]))
        }
        _ = await (firstLoad.value, secondLoad.value)
        let traffic = connection.traffic()
        #expect(traffic.calls("specialist.list").count == 1)
        #expect(traffic.calls("models.list").count == 1)
        #expect(traffic.calls("models.list").first?.params["providerId"] as? String == "auggie")
        #expect(traffic.calls("host.providerAuthStatus").isEmpty)
        #expect(traffic.calls("providers.catalog").isEmpty)
        #expect(first.specialistName == "Fixture specialist" && second.specialistName == "Fixture specialist")
        #expect(traffic.pendingCount == 0)
        printCatalogLedger("concurrent-catalog-consumers", traffic)
    }

    func configureCatalogs(_ fixture: ConversationStartupFixture) {
        fixture.modelId = "fixture-model"
        fixture.providerId = "auggie"
        fixture.parentMetadata["specialist"] = "fixture-specialist"
        fixture.connection.responseMap["specialist.list"] = [
            "specialists": [["id": "fixture-specialist", "name": "Fixture specialist"]]
        ]
        fixture.connection.responseMap["models.list"] = [
            "models": [["id": "fixture-model", "name": "Fixture model", "provider": "auggie"]]
        ]
    }
}
