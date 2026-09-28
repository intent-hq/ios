import Foundation
@testable import Intent
import Testing

extension CreationOptionsStoreTests {
    func catalogStore() -> (CreationOptionsStore, RPCRecordingConnection) {
        let connection = RPCRecordingConnection()
        connection.simulateConnect()
        connection.responseMap["specialist.list"] = specialistReply("Known specialist")
        connection.responseMap["models.list"] = modelReply("Known model")
        return (CreationOptionsStore(connectionManager: connection), connection)
    }

    func specialistReply(_ name: String) -> [String: Any] {
        ["specialists": [["id": "specialist", "name": name, "description": "Description"]]]
    }

    func modelReply(_ name: String) -> [String: Any] {
        ["models": [["id": "model", "name": name, "provider": "auggie"]]]
    }

    func catalogEvent(_ connection: RPCRecordingConnection, type: String, paths: [String] = []) {
        let data: [String: Any] = type == "settings:changed"
            ? ["changes": paths.map { ["path": $0, "value": "fixture"] }, "revision": 1]
            : ["workspaceId": "workspace"]
        connection.deliverEvent(method: "event", params: ["event": ["type": type, "data": data]])
    }

    @Test(arguments: [false, true])
    func labelEnsuresReuseSuccessfulCatalogsIncludingEmpty(empty: Bool) async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        if empty {
            connection.responseMap["specialist.list"] = ["specialists": []]
            connection.responseMap["models.list"] = ["models": []]
        }
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        printCatalogLedger(empty ? "empty-cold" : "catalog-cold", connection.traffic())
        #expect(connection.traffic().methodCounts == ["specialist.list": 1, "models.list": 1])
        #expect(store.models(for: "auggie") != nil)
        #expect(store.specialists.isEmpty == empty)
        let checkpoint = connection.checkpoint
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        try await expectNever("silent catalog revalidation") { !connection.traffic(since: checkpoint).requests.isEmpty }
        printCatalogLedger(empty ? "empty-warm" : "catalog-warm", connection.traffic(since: checkpoint))
    }

    @Test(arguments: [false, true])
    func oneCancelledEnsureDoesNotCancelOtherWaiters(models: Bool) async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let method = models ? "models.list" : "specialist.list"
        connection.pendingMethods = [method]
        var cancelledReturned = false
        let cancelled = Task {
            if models { await store.ensureModels(providerId: "auggie") } else { await store.ensureSpecialists() }
            cancelledReturned = true
        }
        var otherEntered = false
        let surviving = Task {
            otherEntered = true
            if models { await store.ensureModels(providerId: "auggie") } else { await store.ensureSpecialists() }
        }
        defer { cancelled.cancel(); surviving.cancel() }
        try await waitUntil("both catalog callers") { otherEntered && connection.pendingRequestCount(method) == 1 }
        cancelled.cancel()
        try await waitUntil("cancelled label caller returns before reply") { cancelledReturned }
        #expect(connection.pendingRequestCount(method) == 1)
        connection.resolvePending(method, with: models ? modelReply("Shared reply") : specialistReply("Shared reply"))
        await surviving.value
        #expect(models ? store.models(for: "auggie")?.first?.name == "Shared reply" : store.specialists.first?.name == "Shared reply")
        #expect(connection.traffic().methodCounts == [method: 1])
        #expect(connection.traffic().failures.isEmpty)
        printCatalogLedger(models ? "models-concurrent-cancellation" : "specialists-concurrent-cancellation", connection.traffic())
    }

    @Test func finalReleaseRejectsLateReplyAcrossReappearance() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let consumer = UUID()
        let staleReply = TestGate()
        var calls = 0
        connection.suspendedResponse = { method, _ in
            guard method == "specialist.list" else { return nil }
            calls += 1
            if calls == 1 { await staleReply.wait(); return self.specialistReply("Stale") }
            return self.specialistReply("Current")
        }
        store.retainSpecialists(consumer: consumer)
        let first = Task { await store.ensureSpecialists(consumer: consumer) }
        defer { staleReply.open(); first.cancel() }
        try await waitUntil("sent catalog request") { calls == 1 }
        store.releaseCatalogs(consumer: consumer)
        await first.value
        store.retainSpecialists(consumer: consumer)
        await store.ensureSpecialists(consumer: consumer)
        #expect(store.specialists.first?.name == "Current")
        staleReply.open()
        try await waitUntil("late catalog reply accounted") { connection.traffic().pendingCount == 0 }
        #expect(store.specialists.first?.name == "Current")
        #expect(connection.traffic().methodCounts == ["specialist.list": 2])
        printCatalogLedger("retired-reappearance", connection.traffic())
    }

    @Test func releasingInterestBeforeScheduledRefreshStartsSendsNothing() async throws {
        let (store, connection) = catalogStore()
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        await store.ensureSpecialists()
        let checkpoint = connection.checkpoint
        catalogEvent(connection, type: "specialists:changed")
        store.releaseCatalogs(consumer: consumer)
        try await expectNever("refresh after final interest release") { !connection.traffic(since: checkpoint).requests.isEmpty }
        #expect(store.specialists.first?.name == "Known specialist")
        #expect(connection.eventHandlerCount == 1) // One cache-invalidating session listener, no view listener.
        store.reset()
        #expect(connection.eventHandlerCount == 0)
        // Work scheduled by a departing view cannot resurrect a torn-down
        // backend session, even if that caller itself was not cancelled yet.
        store.retainCreationOptions(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        await store.loadIfNeeded()
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(connection.eventHandlerCount == 0)
        catalogEvent(connection, type: "specialists:changed")
        connection.simulateDisconnect()
        connection.simulateConnect()
        try await expectNever("catalog work after session teardown") { !connection.traffic(since: checkpoint).requests.isEmpty }
        printCatalogLedger("final-interest-session-cleanup", connection.traffic(since: checkpoint))
    }

    @Test func releasingStoreRemovesSessionListener() async {
        let connection = RPCRecordingConnection()
        connection.responseMap["specialist.list"] = ["specialists": []]
        var store: CreationOptionsStore? = CreationOptionsStore(connectionManager: connection)
        await store?.ensureSpecialists()
        #expect(connection.eventHandlerCount == 1)
        weak var released = store
        store = nil
        #expect(released == nil)
        #expect(connection.eventHandlerCount == 0)
    }

    @Test func closedPickerCancelsQueuedRevalidationAndInactiveReconnect() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        connection.responseMap["host.providerAuthStatus"] = ["providers": []]
        let consumer = UUID()
        store.retainCreationOptions(consumer: consumer)
        store.selectModelProvider("auggie", consumer: consumer)
        await store.loadIfNeeded(consumer: consumer)
        await store.loadModelsIfNeeded(providerId: "auggie", consumer: consumer)
        printCatalogLedger("explicit-creation-picker", connection.traffic())
        let checkpoint = connection.checkpoint
        await store.loadIfNeeded(consumer: consumer)
        store.releaseCatalogs(consumer: consumer)
        try await expectNever("closed options picker revalidation") { !connection.traffic(since: checkpoint).requests.isEmpty }
        store.selectModelProvider("auggie", consumer: consumer)
        await store.loadModelsIfNeeded(providerId: "auggie", consumer: consumer)
        store.releaseCatalogs(consumer: consumer)
        connection.simulateDisconnect()
        connection.simulateConnect()
        try await expectNever("closed picker revalidation") { !connection.traffic(since: checkpoint).requests.isEmpty }
        #expect(connection.eventHandlerCount == 1)
        printCatalogLedger("closed-picker", connection.traffic(since: checkpoint))
    }
}

@MainActor
func printCatalogLedger(_ scenario: String, _ traffic: RPCTraffic) {
    let methods = traffic.methodCounts.keys.sorted().map { "\($0)=\(traffic.methodCounts[$0] ?? 0)" }.joined(separator: ",")
    print("Catalog ledger \(scenario): [\(methods)] \(traffic.summary)")
}
