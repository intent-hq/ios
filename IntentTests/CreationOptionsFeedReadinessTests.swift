import Foundation
@testable import Intent
import Testing

extension CreationOptionsStoreTests {
    @Test(arguments: [false, true], [false, true])
    func catalogFeedRecoveryReconcilesUncoveredReads(replyBeforeFeed: Bool, failed: Bool) async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        connection.globalSubscriptionState = failed ? .failed(attempts: 2, lastError: "Unavailable") : .subscribing(attempt: 1)
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        connection.pendingMethods = ["specialist.list", "models.list"]
        let load = Task {
            async let specialists: () = store.ensureSpecialists(consumer: consumer)
            await store.ensureModels(providerId: "auggie", consumer: consumer)
            await specialists
        }
        defer { load.cancel() }
        try await connection.waitForPendingRequests("specialist.list")
        try await connection.waitForPendingRequests("models.list")
        if replyBeforeFeed {
            connection.resolvePending("specialist.list", with: specialistReply("Before feed"))
            connection.resolvePending("models.list", with: modelReply("Before feed"))
            await load.value
        }
        connection.globalSubscriptionState = .subscribing(attempt: 2)
        connection.globalSubscriptionState = .subscribed
        connection.globalSubscriptionState = .subscribed
        if !replyBeforeFeed {
            connection.resolvePending("specialist.list", with: specialistReply("Before feed"))
            connection.resolvePending("models.list", with: modelReply("Before feed"))
        }
        try await waitUntil("covered catalog reconciliation") {
            connection.traffic().calls("specialist.list").count == 2 && connection.traffic().calls("models.list").count == 2
        }
        #expect(!store.specialistCatalog.isFresh && !store.modelCatalog(for: "auggie").isFresh)
        connection.resolvePending("specialist.list", with: specialistReply("After feed"))
        connection.resolvePending("models.list", with: modelReply("After feed"))
        await load.value
        await store.ensureSpecialists(consumer: consumer)
        await store.ensureModels(providerId: "auggie", consumer: consumer)
        #expect(store.specialists.first?.name == "After feed")
        #expect(store.models(for: "auggie")?.first?.name == "After feed")
        #expect(connection.traffic().methodCounts == ["specialist.list": 2, "models.list": 2])
        printCatalogLedger("feed-recovery-reply-first-\(replyBeforeFeed)-failed-\(failed)", connection.traffic())
        try await expectReadyReplayIsQuiet(store, connection: connection)
    }

    @Test func catalogReadStartingAfterFeedReadinessNeedsOnlyOneRequest() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        connection.globalSubscriptionState = .subscribed
        await store.ensureSpecialists(consumer: consumer)
        await store.ensureModels(providerId: "auggie", consumer: consumer)
        #expect(connection.traffic().methodCounts == ["specialist.list": 1, "models.list": 1])
        printCatalogLedger("feed-ready-before-read", connection.traffic())
        try await expectReadyReplayIsQuiet(store, connection: connection)
    }

    @Test(arguments: [false, true])
    func catalogFeedRecoveryExpiresIdleAndReleasedCaches(empty: Bool) async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        if empty {
            connection.responseMap["specialist.list"] = ["specialists": []]
            connection.responseMap["models.list"] = ["models": []]
        }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        await store.ensureSpecialists(consumer: consumer)
        await store.ensureModels(providerId: "auggie", consumer: consumer)
        await store.ensureModels(providerId: "codex") // Idle, never selected.
        store.releaseCatalogs(consumer: consumer)
        let checkpoint = connection.checkpoint
        connection.globalSubscriptionState = .subscribed
        try await expectNever("uninterested feed recovery reads") { !connection.traffic(since: checkpoint).requests.isEmpty }
        #expect(!store.specialistCatalog.isFresh)
        #expect(!store.modelCatalog(for: "auggie").isFresh && !store.modelCatalog(for: "codex").isFresh)
        #expect(store.models(for: "codex") != nil)
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 1, "models.list": 1])
        #expect(connection.traffic(since: checkpoint).calls("models.list").first?.params["providerId"] as? String == "auggie")
        printCatalogLedger("feed-idle-recovery-empty-\(empty)", connection.traffic(since: checkpoint))
        try await expectReadyReplayIsQuiet(store, connection: connection)
    }

    @Test func lostFeedRecoveryPreservesLastGoodLabelsOnFailure() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        let checkpoint = connection.checkpoint
        connection.globalSubscriptionState = .failed(attempts: 2, lastError: "Unavailable")
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        connection.errorMap["specialist.list"] = URLError(.networkConnectionLost)
        connection.errorMap["models.list"] = URLError(.networkConnectionLost)
        connection.globalSubscriptionState = .subscribed
        try await waitUntil("failed feed reconciliation") { store.specialistCatalog.loadFailed && store.modelCatalog(for: "auggie").loadFailed }
        #expect(store.specialists.first?.name == "Known specialist")
        #expect(store.models(for: "auggie")?.first?.name == "Known model")
        connection.globalSubscriptionState = .subscribed
        try await expectNever("automatic feed failure retry") { connection.traffic(since: checkpoint).requests.count > 2 }
        connection.errorMap = [:]
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 2, "models.list": 2])
        #expect(store.specialistCatalog.isFresh && store.modelCatalog(for: "auggie").isFresh)
        printCatalogLedger("feed-reconciliation-failure-retry", connection.traffic(since: checkpoint))
    }

    @Test(arguments: [false, true])
    func catalogFeedObserverEndsWithSession(reset: Bool) async throws {
        let connection = RPCRecordingConnection()
        connection.simulateConnect()
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        var store: CreationOptionsStore? = CreationOptionsStore(connectionManager: connection)
        weak var released = store
        store?.retainSpecialists(consumer: UUID())
        store?.selectModelProvider("auggie", consumer: UUID())
        if reset { store?.reset() }
        if !reset { store = nil }
        connection.globalSubscriptionState = .subscribed
        try await expectNever("retired session feed reconciliation") { !connection.traffic().requests.isEmpty }
        #expect(connection.eventHandlerCount == 0)
        store = nil
        #expect(released == nil)
    }

    @Test func releasedCatalogReadCannotRegainFreshnessAfterFeedRecovery() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        connection.pendingMethods = ["specialist.list"]
        let old = Task { await store.ensureSpecialists(consumer: consumer) }
        try await connection.waitForPendingRequests("specialist.list")
        store.releaseCatalogs(consumer: consumer)
        await old.value
        connection.globalSubscriptionState = .subscribed
        connection.resolvePending("specialist.list", with: specialistReply("Obsolete"))
        try await waitUntil("released reply accounted") { connection.traffic().pendingCount == 0 }
        #expect(store.specialists.isEmpty && !store.specialistCatalog.isFresh)
        try await expectNever("uninterested recovery follow-up") { connection.traffic().requests.count > 1 }
        connection.pendingMethods = []
        await store.ensureSpecialists()
        #expect(store.specialists.first?.name == "Known specialist")
        #expect(connection.traffic().methodCounts == ["specialist.list": 2])
        printCatalogLedger("feed-recovery-released-read", connection.traffic())
    }

    @Test func repeatedFeedGapsDuringCatalogFlightRemainBounded() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        store.selectModelProvider("auggie", consumer: UUID())
        connection.pendingMethods = ["models.list"]
        let load = Task { await store.ensureModels(providerId: "auggie") }
        try await connection.waitForPendingRequests("models.list")
        for round in 0..<2 {
            for _ in 0..<10 {
                connection.globalSubscriptionState = .subscribing(attempt: 1)
                connection.globalSubscriptionState = .subscribed
            }
            connection.resolvePending("models.list", with: modelReply("Obsolete"))
            if round == 0 {
                try await waitUntil("one trailing covered read") { connection.traffic().requests.count == 2 }
            }
        }
        await load.value
        #expect(store.models(for: "auggie") == nil && !store.modelCatalog(for: "auggie").isFresh)
        try await expectNever("unbounded feed recovery loop") { connection.traffic().requests.count > 2 }
        printCatalogLedger("feed-recovery-inflight-burst", connection.traffic())
        let checkpoint = connection.checkpoint
        connection.pendingMethods = []
        await store.ensureModels(providerId: "auggie")
        #expect(store.models(for: "auggie")?.first?.name == "Known model")
        #expect(connection.traffic(since: checkpoint).methodCounts == ["models.list": 1])
        printCatalogLedger("feed-recovery-burst-retry", connection.traffic(since: checkpoint))
    }

    private func expectReadyReplayIsQuiet(_ store: CreationOptionsStore, connection: RPCRecordingConnection) async throws {
        let checkpoint = connection.checkpoint
        connection.globalSubscriptionState = .subscribed
        connection.globalSubscriptionState = .subscribed
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        try await expectNever("warm feed replay read") { !connection.traffic(since: checkpoint).requests.isEmpty }
    }
}
