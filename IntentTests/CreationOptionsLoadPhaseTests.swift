import Foundation
@testable import Intent
import Testing

/// The creation picker's specialist + provider load is one `LoadPhase`. A
/// silent revalidation of a loaded catalog never shows loading or failure.
@MainActor
struct CreationOptionsLoadPhaseTests {
    private func makeFake() -> FakeConnectionManager {
        let fake = FakeConnectionManager()
        fake.responseMap["specialist.list"] = ["specialists": [["id": "implementor", "name": "Implementor", "description": "d"]]]
        fake.responseMap["host.providerAuthStatus"] = ["providers": [["id": "auggie", "authenticated": true]]]
        return fake
    }

    @Test func movesFromLoadingToLoaded() async throws {
        let fake = makeFake()
        fake.pendingMethods = ["specialist.list"]
        let store = CreationOptionsStore(connectionManager: fake)
        let load = Task { await store.loadIfNeeded() }
        try await fake.waitForPendingRequests("specialist.list")
        #expect(store.loadPhase == .loading(lastLoadedAt: nil))

        fake.resolvePending("specialist.list", with: ["specialists": [["id": "implementor", "name": "Implementor", "description": "d"]]])
        await load.value
        #expect(store.loadPhase.hasLoaded && !store.isLoading)
        #expect(store.specialists.map(\.id) == ["implementor"])
    }

    @Test func emptyCatalogsAreLoadedNotFailed() async {
        let fake = FakeConnectionManager()
        fake.responseMap["specialist.list"] = ["specialists": [] as [[String: Any]]]
        fake.responseMap["host.providerAuthStatus"] = ["providers": [] as [[String: Any]]]
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        #expect(store.loadPhase.hasLoaded)
        #expect(store.specialists.isEmpty && store.providers.isEmpty)
    }

    @Test func aFailedColdLoadIsFailedNotLoading() async {
        let fake = makeFake()
        fake.errorMap["host.providerAuthStatus"] = URLError(.timedOut)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        #expect(store.loadPhase == .failed("Creation options could not be loaded."))
        #expect(!store.isLoading && !store.hasLoaded)
    }

    @Test func aSilentRevalidationNeitherShowsLoadingNorDropsTheCatalogWhenItFails() async throws {
        let fake = makeFake()
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        let loadedAt = try #require(store.loadPhase.lastLoadedAt)
        fake.pendingMethods = ["specialist.list"]

        let refresh = Task { await store.loadIfNeeded(force: true) }
        try await fake.waitForPendingRequests("specialist.list")
        #expect(store.loadPhase == .loaded(loadedAt), "no spinner over cached lists")
        fake.failPending("specialist.list", with: URLError(.notConnectedToInternet))
        await refresh.value

        #expect(store.loadPhase == .loaded(loadedAt))
        #expect(store.specialists.map(\.id) == ["implementor"])
    }

    @Test func invalidatingReturnsToIdle() async {
        let fake = makeFake()
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        store.invalidate()
        #expect(store.loadPhase == .idle)
    }
}
