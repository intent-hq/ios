import Foundation
@testable import Intent
import Testing

@MainActor
struct CreationOptionsStoreTests {
    private func specialistDict(id: String, name: String? = nil, role: String? = nil) -> [String: Any] {
        var dict: [String: Any] = ["id": id, "name": name ?? id.capitalized, "description": "d"]
        if let role {
            dict["role"] = role
        }
        return dict
    }

    private func providerDict(id: String, authenticated: Any? = true) -> [String: Any] {
        var dict: [String: Any] = ["id": id]
        if let authenticated {
            dict["authenticated"] = authenticated
        }
        return dict
    }

    func modelDict(id: String, provider: String = "auggie", isDefault: Bool = false) -> [String: Any] {
        ["id": id, "name": "\(id) (balanced)", "provider": provider, "isDefault": isDefault]
    }

    private func configureLoadResponses(_ fake: FakeConnectionManager) {
        fake.responseMap["specialist.list"] = [
            "specialists": [
                specialistDict(id: "implementor"),
                specialistDict(id: "coordinator", role: "orchestrator")
            ]
        ]
        fake.responseMap["host.providerAuthStatus"] = [
            "providers": [
                providerDict(id: "auggie", authenticated: true),
                providerDict(id: "claude-code", authenticated: false)
            ]
        ]
        fake.responseMap["models.list"] = ["models": [modelDict(id: "sonnet4.5")]]
    }

    func makeLoadedStore() async -> (store: CreationOptionsStore, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        return (store, fake)
    }

    func waitFor(
        _ description: String = "condition",
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        try await waitUntil(description, sourceLocation: sourceLocation, condition)
    }

    func spawnedWork(_ store: CreationOptionsStore) -> [Task<Void, Never>?] {
        let catalogs = [store.specialistCatalog.latestReadTask, store.defaultModelProviderCatalog.latestReadTask]
        return [store.latestLoadTask, store.latestCreationRefreshTask] + catalogs
            + store.modelCatalogs.keys.sorted().map { store.modelCatalogs[$0]?.latestReadTask }
    }

    // MARK: - Cold load

    @Test func coldLoadIssuesBothReadsAndMarksLoaded() async {
        let (store, fake) = await makeLoadedStore()
        #expect(fake.paramsForMethod("specialist.list").count == 1)
        #expect(fake.paramsForMethod("host.providerAuthStatus").count == 1)
        #expect(fake.didCallMethod("models.list") == false)
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.specialists.orchestrator?.id == "coordinator")
        #expect(store.providers == [
            ProviderInfo(id: "auggie", authenticated: true),
            ProviderInfo(id: "claude-code", authenticated: false)
        ])
        #expect(store.hasLoaded)
        #expect(store.lastLoadedAt != nil)
        #expect(store.isLoading == false)
    }

    @Test func coldLoadShowsLoadingUntilBothReadsAnswer() async throws {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        fake.pendingMethods = ["host.providerAuthStatus"]
        let store = CreationOptionsStore(connectionManager: fake)

        let load = Task { await store.loadIfNeeded() }
        try await waitFor("reads") { fake.didCallMethod("host.providerAuthStatus") }
        #expect(store.isLoading)
        #expect(store.hasLoaded == false)

        fake.resolvePending("host.providerAuthStatus", with: ["providers": [providerDict(id: "auggie")]])
        await load.value
        #expect(store.isLoading == false)
        #expect(store.hasLoaded)
        #expect(store.providers.map(\.id) == ["auggie"])
    }

    @Test func providersParseTriStateAuthenticatedAndSkipEntriesWithoutId() async {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        fake.responseMap["host.providerAuthStatus"] = [
            "providers": [
                providerDict(id: "auggie", authenticated: true),
                providerDict(id: "claude-code", authenticated: false),
                providerDict(id: "grok", authenticated: NSNull()),
                providerDict(id: "pi", authenticated: nil),
                ["authenticated": true]
            ]
        ]
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        #expect(store.providers == [
            ProviderInfo(id: "auggie", authenticated: true),
            ProviderInfo(id: "claude-code", authenticated: false),
            ProviderInfo(id: "grok", authenticated: .unknown),
            ProviderInfo(id: "pi", authenticated: .unknown)
        ])
    }

    @Test func specialistsSkipUnparsableRows() async {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        fake.responseMap["specialist.list"] = [
            "specialists": [
                specialistDict(id: "implementor"),
                ["id": "broken"]
            ]
        ]
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        #expect(store.specialists.map(\.id) == ["implementor"])
        #expect(store.hasLoaded)
    }

    // MARK: - Stale-while-revalidate

    @Test func secondLoadIfNeededKeepsDataAndRevalidatesSilently() async throws {
        let (store, fake) = await makeLoadedStore()
        let cachedSpecialists = store.specialists.map(\.id)
        let cachedProviders = store.providers
        fake.pendingMethods = ["specialist.list"]

        await store.loadIfNeeded()

        try await waitFor("refresh reads") {
            fake.paramsForMethod("specialist.list").count == 2
                && fake.paramsForMethod("host.providerAuthStatus").count == 2
        }
        #expect(store.isLoading == false)
        #expect(store.hasLoaded)
        #expect(store.specialists.map(\.id) == cachedSpecialists)
        #expect(store.providers == cachedProviders)

        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "fresh")]])
        try await waitFor("refresh completion") { store.specialists.map(\.id) == ["fresh"] }
        #expect(store.isLoading == false)
    }

    @Test func concurrentColdLoadsShareOneFlight() async throws {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)

        fake.pendingMethods = ["specialist.list"]
        let first = Task { await store.loadIfNeeded() }
        let second = Task { await store.loadIfNeeded() }
        try await waitFor("cold read") { fake.paramsForMethod("specialist.list").count == 1 }
        #expect(!store.hasLoaded)
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "implementor")]])
        _ = await (first.value, second.value)

        #expect(store.hasLoaded)
        #expect(store.specialists.map(\.id) == ["implementor"])
        #expect(fake.paramsForMethod("specialist.list").count == 1)
        #expect(fake.paramsForMethod("host.providerAuthStatus").count == 1)
    }

    @Test func forceRefetchesEvenWhenCached() async {
        let (store, fake) = await makeLoadedStore()
        fake.responseMap["specialist.list"] = ["specialists": [specialistDict(id: "fresh")]]

        await store.loadIfNeeded(force: true)

        #expect(fake.paramsForMethod("specialist.list").count == 2)
        #expect(store.specialists.map(\.id) == ["fresh"])
        #expect(store.hasLoaded)
        #expect(store.isLoading == false)
    }

    @Test func failedBackgroundRefreshKeepsCachedLists() async throws {
        let (store, fake) = await makeLoadedStore()
        let cachedSpecialists = store.specialists.map(\.id)
        let cachedProviders = store.providers
        fake.errorMap["specialist.list"] = NSError(domain: "t", code: -1)
        fake.errorMap["host.providerAuthStatus"] = NSError(domain: "t", code: -1)

        await store.loadIfNeeded()
        let refresh = try #require(store.latestLoadTask)
        await refresh.value
        #expect(fake.paramsForMethod("specialist.list").count == 2)

        #expect(store.specialists.map(\.id) == cachedSpecialists)
        #expect(store.providers == cachedProviders)
        #expect(store.isLoading == false)
    }

    @Test func failedColdLoadLeavesHasLoadedFalseSoNextCallRetries() async {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        fake.errorMap["host.providerAuthStatus"] = NSError(domain: "t", code: -1)
        let store = CreationOptionsStore(connectionManager: fake)

        await store.loadIfNeeded()
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.providers.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)

        fake.errorMap["host.providerAuthStatus"] = nil
        await store.loadIfNeeded()
        #expect(store.hasLoaded)
        #expect(store.providers.map(\.id) == ["auggie", "claude-code"])
        #expect(fake.paramsForMethod("host.providerAuthStatus").count == 2)
    }
}

extension CreationOptionsStoreTests {
    // MARK: - Invalidate

    @Test func invalidateEmptiesListsAndResetsHasLoaded() async {
        let (store, _) = await makeLoadedStore()
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])

        store.invalidate()

        #expect(store.specialists.isEmpty)
        #expect(store.providers.isEmpty)
        #expect(store.models(for: "auggie") == nil)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)
    }

    @Test func invalidateBumpsObservableLoadGeneration() async {
        let (store, _) = await makeLoadedStore()
        let generation = store.loadGeneration
        await store.loadIfNeeded()
        #expect(store.loadGeneration == generation)

        store.invalidate()
        #expect(store.loadGeneration == generation + 1)
    }

    @Test func loadAfterInvalidateRunsCold() async throws {
        let (store, fake) = await makeLoadedStore()
        store.invalidate()
        fake.pendingMethods = ["specialist.list"]

        let load = Task { await store.loadIfNeeded() }
        try await waitFor("cold read") { fake.paramsForMethod("specialist.list").count == 2 }
        #expect(store.isLoading)

        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "fresh")]])
        await load.value
        #expect(store.specialists.map(\.id) == ["fresh"])
        #expect(store.hasLoaded)
        #expect(store.isLoading == false)
    }

    @Test func invalidateDuringPendingRefreshRejectsStaleCompletion() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.pendingMethods = ["specialist.list"]
        await store.loadIfNeeded()
        try await waitFor("refresh read") { fake.paramsForMethod("specialist.list").count == 2 }
        let staleLoad = try #require(store.latestLoadTask)
        let staleRead = try #require(store.specialistCatalog.latestReadTask)

        store.invalidate()
        #expect(store.specialists.isEmpty)
        #expect(store.hasLoaded == false)

        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "stale")]])
        await staleRead.value
        await staleLoad.value
        #expect(store.specialists.isEmpty)
        #expect(store.providers.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)

        fake.pendingMethods = []
        fake.responseMap["specialist.list"] = ["specialists": [specialistDict(id: "fresh")]]
        await store.loadIfNeeded()
        #expect(store.specialists.map(\.id) == ["fresh"])
        #expect(store.hasLoaded)
        #expect(fake.paramsForMethod("specialist.list").count == 3)
    }

    @Test func loadTaskStartingAfterInvalidateTouchesNothing() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.clearRequestLog()
        let previousLoad = store.latestLoadTask
        await store.loadIfNeeded()
        let refresh = try #require(store.latestLoadTask)
        #expect(refresh != previousLoad)
        store.invalidate()

        await refresh.value
        #expect(fake.requestLog.isEmpty)
        #expect(store.isLoading == false)
        #expect(store.hasLoaded == false)
        #expect(store.specialists.isEmpty)

        await store.loadIfNeeded()
        #expect(store.hasLoaded)
        #expect(store.isLoading == false)
        #expect(fake.paramsForMethod("specialist.list").count == 1)
    }

    // MARK: - Reconnect

    @Test func reconnectRevalidatesAnOpenPickerAndKeepsLastGoodLabels() async throws {
        let (store, fake) = await makeLoadedStore()
        let consumer = UUID()
        store.retainCreationOptions(consumer: consumer)
        defer { store.releaseCatalogs(consumer: consumer) }
        await store.loadModelsIfNeeded(providerId: "auggie")
        fake.responseMap["specialist.list"] = ["specialists": [specialistDict(id: "fresh")]]
        fake.pendingMethods = ["specialist.list", "host.providerAuthStatus"]
        fake.clearRequestLog()

        fake.simulateConnect()

        try await waitFor("reload reads") {
            fake.didCallMethod("specialist.list") && fake.didCallMethod("host.providerAuthStatus")
        }
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.providers.isEmpty)
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading)

        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "fresh")]])
        fake.resolvePending("host.providerAuthStatus", with: ["providers": [providerDict(id: "auggie")]])
        try await waitFor("reload completion") { store.hasLoaded }
        #expect(store.specialists.map(\.id) == ["fresh"])
        #expect(store.providers.map(\.id) == ["auggie"])
        #expect(store.isLoading == false)
        #expect(fake.paramsForMethod("specialist.list").count == 1)
        #expect(fake.didCallMethod("models.list") == false)
    }

    @Test func reconnectRetriesAnOpenPickerAfterFailedColdLoad() async throws {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        fake.errorMap["host.providerAuthStatus"] = NSError(domain: "t", code: -1)
        let store = CreationOptionsStore(connectionManager: fake)
        let consumer = UUID()
        store.retainCreationOptions(consumer: consumer)
        defer { store.releaseCatalogs(consumer: consumer) }
        await store.loadIfNeeded()
        #expect(store.specialists.isEmpty == false)
        #expect(store.hasLoaded == false)

        fake.errorMap["host.providerAuthStatus"] = nil
        fake.clearRequestLog()

        fake.simulateConnect()

        try await waitFor("retry completion") { store.hasLoaded }
        #expect(fake.paramsForMethod("specialist.list").count == 1)
        #expect(fake.paramsForMethod("host.providerAuthStatus").count == 1)
        #expect(store.providers.map(\.id) == ["auggie", "claude-code"])
        #expect(store.isLoading == false)
    }

    @Test func reconnectDoesNotJoinOrApplyPreReconnectRefresh() async throws {
        let (store, fake) = await makeLoadedStore()
        let consumer = UUID()
        store.retainCreationOptions(consumer: consumer)
        defer { store.releaseCatalogs(consumer: consumer) }
        fake.pendingMethods = ["specialist.list"]
        await store.loadIfNeeded()
        try await waitFor("pre-reconnect read") { fake.paramsForMethod("specialist.list").count == 2 }
        let staleLoad = try #require(store.latestLoadTask)
        let staleRead = try #require(store.specialistCatalog.latestReadTask)

        fake.simulateConnect()

        try await waitFor("reconnect read") { fake.paramsForMethod("specialist.list").count == 3 }
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "stale")]])
        await staleRead.value
        await staleLoad.value
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "fresh")]])
        try await waitFor("reconnect completion") { store.hasLoaded }
        #expect(store.specialists.map(\.id) == ["fresh"])
        #expect(store.isLoading == false)
    }

    @Test func reconnectExpiresInactiveModelsWithoutLoadingOptions() async {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        fake.clearRequestLog()
        let before = spawnedWork(store)

        fake.simulateConnect()
        #expect(store.modelCatalog(for: "auggie").isFresh == false)
        #expect(spawnedWork(store) == before)

        #expect(store.loadGeneration == 1)
        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)

        fake.responseMap["models.list"] = ["models": [modelDict(id: "fresh")]]
        await store.ensureModels(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["fresh"])
        #expect(fake.paramsForMethod("models.list").count == 1)
        #expect(fake.didCallMethod("specialist.list") == false)
    }

    @Test func reconnectWithoutCacheDoesNotFetch() {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        let before = spawnedWork(store)

        fake.simulateConnect()
        #expect(spawnedWork(store) == before)

        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)
    }
}
