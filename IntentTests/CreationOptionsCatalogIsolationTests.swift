import Foundation
@testable import Intent
import Testing

extension CreationOptionsStoreTests {
    @Test func backendResetRejectsOldReplyAndDoesNotContaminateOtherBackend() async throws {
        let (first, oldConnection) = catalogStore()
        let (second, newConnection) = catalogStore()
        defer { first.reset(); second.reset() }
        let gate = TestGate()
        oldConnection.suspendedResponse = { method, _ in
            guard method == "specialist.list" else { return nil }
            await gate.wait()
            return self.specialistReply("Old backend")
        }
        let oldLoad = Task { await first.ensureSpecialists() }
        defer { gate.open(); oldLoad.cancel() }
        try await waitUntil("old backend started") { oldConnection.traffic().requests.count == 1 }
        first.reset()
        newConnection.responseMap["specialist.list"] = specialistReply("New backend")
        newConnection.responseMap["models.list"] = modelReply("New backend model")
        await second.ensureSpecialists()
        await second.ensureModels(providerId: "auggie")
        gate.open()
        await oldLoad.value
        try await waitUntil("old backend late reply recorded") { oldConnection.traffic().pendingCount == 0 }
        #expect(first.specialists.isEmpty && first.models(for: "auggie") == nil)
        #expect(second.specialists.first?.name == "New backend")
        #expect(second.models(for: "auggie")?.first?.name == "New backend model")
        #expect(oldConnection.eventHandlerCount == 0)
        #expect(newConnection.traffic().methodCounts == ["specialist.list": 1, "models.list": 1])
        printCatalogLedger("backend-retired", oldConnection.traffic())
        printCatalogLedger("backend-new", newConnection.traffic())
    }

    @Test func disconnectedReplyIsRejectedBeforeReconnectArrives() async throws {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        connection.pendingMethods = ["specialist.list"]
        let load = Task { await store.ensureSpecialists() }
        defer { load.cancel() }
        try await connection.waitForPendingRequests("specialist.list")
        connection.simulateDisconnect()
        connection.resolvePending("specialist.list", with: specialistReply("Disconnected reply"))
        await load.value
        try await waitUntil("disconnected reply recorded") { connection.traffic().pendingCount == 0 }
        #expect(store.specialists.isEmpty)
        connection.pendingMethods = []
        connection.simulateConnect()
        try await waitUntil("fresh connected labels") { store.specialists.first?.name == "Known specialist" }
        #expect(connection.traffic().methodCounts == ["specialist.list": 2])
        printCatalogLedger("disconnected-late-reply-and-reconnect", connection.traffic())
    }

    @Test func invalidEnvelopesRemainRetryableRatherThanCachingEmpty() async {
        let (store, connection) = catalogStore()
        defer { store.reset() }
        connection.responseMap["specialist.list"] = ["unexpected": []]
        connection.responseMap["models.list"] = ["unexpected": []]
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        #expect(store.specialistCatalog.loadFailed)
        #expect(store.modelCatalog(for: "auggie").loadFailed)
        connection.responseMap["specialist.list"] = ["specialists": []]
        connection.responseMap["models.list"] = ["models": []]
        await store.ensureSpecialists()
        await store.ensureModels(providerId: "auggie")
        #expect(store.specialistCatalog.isFresh)
        #expect(store.models(for: "auggie")?.isEmpty == true)
        #expect(connection.traffic().methodCounts == ["specialist.list": 2, "models.list": 2])
        printCatalogLedger("invalid-envelope-and-retry", connection.traffic())
    }
}
