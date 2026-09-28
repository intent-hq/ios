import Foundation
@testable import Intent
import Testing

extension CreationOptionsStoreTests {
    @Test func catalogEventsRefreshOnlyRelevantInterestedCaches() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        await store.ensureModels(providerId: "codex") // Cached, no active consumer.
        let generation = store.loadGeneration
        let checkpoint = connection.checkpoint
        catalogEvent(connection, type: "settings:changed", paths: ["theme.color", "modelsUnrelated", "specialistsUnrelated"])
        try await expectNever("unrelated settings read") { !connection.traffic(since: checkpoint).requests.isEmpty }
        catalogEvent(connection, type: "specialists:changed")
        try await waitUntil("specialists refreshed") { store.specialistCatalog.isFresh }
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 1])
        catalogEvent(connection, type: "settings:changed", paths: ["model.default"])
        try await waitUntil("interested model and specialists refreshed") {
            store.modelCatalog(for: "auggie").isFresh && store.specialistCatalog.isFresh
        }
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 2, "models.list": 1])
        #expect(store.loadGeneration == generation) // No parent metadata invalidation.
        #expect(!store.modelCatalog(for: "codex").isFresh)
        #expect(connection.traffic(since: checkpoint).calls("models.list").allSatisfy { $0.params["providerId"] as? String == "auggie" })
        printCatalogLedger("settings-specialist-invalidation", connection.traffic(since: checkpoint))
        let next = connection.checkpoint
        store.selectModelProvider("codex", consumer: consumer)
        await store.ensureModels(providerId: "codex")
        catalogEvent(connection, type: "settings:changed", paths: ["providers.paths.auggie"])
        try await expectNever("unselected provider refresh") { connection.traffic(since: next).requests.count > 1 }
        #expect(!store.modelCatalog(for: "auggie").isFresh)
        #expect(store.modelCatalog(for: "codex").isFresh)
        printCatalogLedger("provider-selection", connection.traffic(since: next))
    }

    @Test(arguments: [false, true])
    func invalidationBurstsHaveAtMostOneTrailingRead(models: Bool) async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        let method = models ? "models.list" : "specialist.list"
        connection.pendingMethods = [method]
        let initial = Task {
            if models { await store.ensureModels(providerId: "auggie") } else { await store.ensureSpecialists() }
        }
        defer { initial.cancel() }
        try await connection.waitForPendingRequests(method)
        let eventType = models ? "settings:changed" : "specialists:changed"
        let paths = models ? ["providers.paths.auggie"] : []
        for _ in 0..<10 { catalogEvent(connection, type: eventType, paths: paths) }
        #expect(connection.traffic().calls(method).count == 1)
        connection.resolvePending(method, with: models ? modelReply("Obsolete") : specialistReply("Obsolete"))
        try await waitUntil("one trailing catalog read") { connection.traffic().calls(method).count == 2 }
        for _ in 0..<10 { catalogEvent(connection, type: eventType, paths: paths) }
        connection.resolvePending(method, with: models ? modelReply("Also obsolete") : specialistReply("Also obsolete"))
        await initial.value
        try await expectNever("unbounded catalog refresh loop") { connection.traffic().calls(method).count > 2 }
        #expect(store.models(for: "auggie") == nil)
        #expect(store.specialists.isEmpty)
        printCatalogLedger(models ? "models-inflight-burst" : "specialists-inflight-burst", connection.traffic())
        let checkpoint = connection.checkpoint
        connection.pendingMethods = []
        if models { await store.ensureModels(providerId: "auggie") } else { await store.ensureSpecialists() }
        #expect(connection.traffic(since: checkpoint).methodCounts == [method: 1])
        #expect(models ? store.models(for: "auggie")?.first?.name == "Known model" : store.specialists.first?.name == "Known specialist")
        printCatalogLedger(models ? "models-burst-retry" : "specialists-burst-retry", connection.traffic(since: checkpoint))
    }

    @Test func duplicateConnectedIsWarmAndRealReconnectRefreshesOnlyInterests() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        let generation = store.loadGeneration
        let checkpoint = connection.checkpoint
        connection.simulateConnect()
        connection.simulateConnect()
        try await expectNever("duplicate connected catalog read") { !connection.traffic(since: checkpoint).requests.isEmpty }
        #expect(store.loadGeneration == generation)
        printCatalogLedger("duplicate-connected", connection.traffic(since: checkpoint))
        connection.simulateDisconnect()
        connection.simulateConnect()
        try await waitUntil("reconnected catalog values") {
            store.specialistCatalog.isFresh && store.modelCatalog(for: "auggie").isFresh
        }
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 1, "models.list": 1])
        printCatalogLedger("interested-reconnect", connection.traffic(since: checkpoint))
        store.releaseCatalogs(consumer: consumer)
        let inactive = connection.checkpoint
        connection.simulateDisconnect()
        connection.simulateConnect()
        try await expectNever("uninterested reconnect read") { !connection.traffic(since: inactive).requests.isEmpty }
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        #expect(connection.traffic(since: inactive).methodCounts == ["specialist.list": 1, "models.list": 1])
        printCatalogLedger("inactive-reconnect-next-consumer", connection.traffic(since: inactive))
    }

    @Test func failedRefreshKeepsLastGoodLabelsAndEnsuresRetry() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        let checkpoint = connection.checkpoint
        // A local injected transport failure has no inbound frame; its full
        // measured cost is the outgoing request, not an invented error body.
        connection.errorMap["specialist.list"] = URLError(.networkConnectionLost)
        connection.errorMap["models.list"] = URLError(.networkConnectionLost)
        catalogEvent(connection, type: "settings:changed", paths: ["model.default"])
        try await waitUntil("both failed refreshes") { store.specialistCatalog.loadFailed && store.modelCatalog(for: "auggie").loadFailed }
        #expect(store.specialists.first?.name == "Known specialist")
        #expect(store.models(for: "auggie")?.first?.name == "Known model")
        #expect(connection.traffic(since: checkpoint).failures.count == 2)
        printCatalogLedger("transport-failure", connection.traffic(since: checkpoint))
        connection.errorMap = [:]
        connection.responseMap["specialist.list"] = specialistReply("Recovered specialist")
        connection.responseMap["models.list"] = modelReply("Recovered model")
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        #expect(store.specialists.first?.name == "Recovered specialist")
        #expect(store.models(for: "auggie")?.first?.name == "Recovered model")
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 2, "models.list": 2])
        printCatalogLedger("transport-failure-and-retry-total", connection.traffic(since: checkpoint))
    }
}
