import Foundation
@testable import Intent
import Testing

/// Session-lifetime specialist / provider / model cache: cold load,
/// explicit stale-while-revalidate, shared reads, hard reset and interested
/// reconnect revalidation while preserving the last successful labels.
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

    /// A fake whose reads answer immediately, plus a store that has
    /// completed its cold specialist/provider load over it.
    func makeLoadedStore() async -> (store: CreationOptionsStore, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        return (store, fake)
    }

    /// Bounded wait until the condition holds, for assertions on
    /// Task-spawned background refreshes. Throws on timeout so a missed
    /// update cannot pass silently.
    func waitFor(
        _ description: String = "condition",
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        try await waitUntil(description, sourceLocation: sourceLocation, condition)
    }

    /// The latest task of each kind the store spawns; unchanged identities
    /// prove a synchronously delivered trigger left nothing to await.
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
        // Models are per provider and not part of the cold load.
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
        // Keep the refresh's specialist read in flight so the mid-refresh
        // state is observable.
        fake.pendingMethods = ["specialist.list"]

        await store.loadIfNeeded()

        // Returned immediately with the cache intact; the background refresh
        // still issues its reads but never flips the loading state.
        try await waitFor("refresh reads") {
            fake.paramsForMethod("specialist.list").count == 2
                && fake.paramsForMethod("host.providerAuthStatus").count == 2
        }
        #expect(store.isLoading == false)
        #expect(store.hasLoaded)
        #expect(store.specialists.map(\.id) == cachedSpecialists)
        #expect(store.providers == cachedProviders)

        // The refresh lands in place once it resolves.
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "fresh")]])
        try await waitFor("refresh completion") { store.specialists.map(\.id) == ["fresh"] }
        #expect(store.isLoading == false)
    }

    @Test func concurrentColdLoadsShareOneFlight() async throws {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)

        // Hold the read open so the second caller enters the store while the
        // first flight is still in flight (a completed flight would turn it
        // into a legitimate stale-while-revalidate refresh).
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
        // Await the background refresh itself, not just its reads.
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
        // Specialists landed, providers did not: not a complete load.
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.providers.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)

        fake.errorMap["host.providerAuthStatus"] = nil
        await store.loadIfNeeded()
        // Retried as an awaited cold load, not a fire-and-forget refresh.
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
        // An open picker observes `loadGeneration` to reload after the
        // reconnect clear; a plain load must not bump it.
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
        // A silent refresh whose specialist read is still in flight.
        fake.pendingMethods = ["specialist.list"]
        await store.loadIfNeeded()
        try await waitFor("refresh read") { fake.paramsForMethod("specialist.list").count == 2 }
        let staleLoad = try #require(store.latestLoadTask)
        let staleRead = try #require(store.specialistCatalog.latestReadTask)

        store.invalidate()
        #expect(store.specialists.isEmpty)
        #expect(store.hasLoaded == false)

        // The superseded refresh completes with data from before the
        // invalidation: it must not repopulate the cache or mark it loaded.
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "stale")]])
        await staleRead.value
        await staleLoad.value
        #expect(store.specialists.isEmpty)
        #expect(store.providers.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)

        // The next call starts a fresh cold load rather than joining the
        // superseded flight.
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
        // The cached path spawns a silent refresh task and returns without
        // suspending, so this invalidate() runs before that task's first
        // line: the task must exit at entry instead of issuing reads.
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

        // The cache is not left in a stuck state: a fresh cold load runs.
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
        // Hold the reload so last-good labels remain observable.
        fake.pendingMethods = ["specialist.list", "host.providerAuthStatus"]
        fake.clearRequestLog()

        fake.simulateConnect()

        try await waitFor("reload reads") {
            fake.didCallMethod("specialist.list") && fake.didCallMethod("host.providerAuthStatus")
        }
        // Labels survive a connection flap; creation/auth readiness is reset.
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
        // Models are reloaded on demand, not by the reconnect.
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

        // Only the open picker retries the partial options load.
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
        // A silent refresh whose specialist read is still in flight when the
        // connection flaps.
        fake.pendingMethods = ["specialist.list"]
        await store.loadIfNeeded()
        try await waitFor("pre-reconnect read") { fake.paramsForMethod("specialist.list").count == 2 }
        let staleLoad = try #require(store.latestLoadTask)
        let staleRead = try #require(store.specialistCatalog.latestReadTask)

        fake.simulateConnect()

        // The reconnect starts its own cold load instead of joining the
        // superseded flight, while last-good labels remain available.
        try await waitFor("reconnect read") { fake.paramsForMethod("specialist.list").count == 3 }
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        // The pre-reconnect read resolves first (oldest pending) with stale
        // data: dropped.
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "stale")]])
        await staleRead.value
        await staleLoad.value
        #expect(store.specialists.map(\.id) == ["implementor", "coordinator"])
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        // The reconnect's own read lands.
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "fresh")]])
        try await waitFor("reconnect completion") { store.hasLoaded }
        #expect(store.specialists.map(\.id) == ["fresh"])
        #expect(store.isLoading == false)
    }

    /// A models-only consumer (the conversation menu, before any creation
    /// picker ran `loadIfNeeded`) keeps last-good data but expires freshness
    /// on reconnect; no inactive catalog is fetched on its behalf.
    @Test func reconnectExpiresInactiveModelsWithoutLoadingOptions() async {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        fake.clearRequestLog()
        let before = spawnedWork(store)

        // The connection sink runs synchronously inside simulateConnect().
        fake.simulateConnect()
        #expect(store.modelCatalog(for: "auggie").isFresh == false)
        #expect(spawnedWork(store) == before)

        #expect(store.loadGeneration == 1)
        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)

        // The consumer's next ensure awaits a fresh catalog.
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

        // The connection sink (if any) runs synchronously inside simulateConnect().
        fake.simulateConnect()
        #expect(spawnedWork(store) == before)

        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)
    }
}
