import Foundation
import Testing
@testable import Intent

/// Session-lifetime specialist / provider / model cache: cold load,
/// stale-while-revalidate, single-flight, invalidation and reconnect
/// hard-clear (same contract as `GitHubRepoStoreTests`).
@MainActor
struct CreationOptionsStoreTests {

    private func specialistDict(id: String, name: String? = nil, role: String? = nil) -> [String: Any] {
        var dict: [String: Any] = ["id": id, "name": name ?? id.capitalized, "description": "d"]
        if let role { dict["role"] = role }
        return dict
    }

    private func providerDict(id: String, authenticated: Any? = true) -> [String: Any] {
        var dict: [String: Any] = ["id": id]
        if let authenticated { dict["authenticated"] = authenticated }
        return dict
    }

    private func modelDict(id: String, provider: String = "auggie", isDefault: Bool = false) -> [String: Any] {
        ["id": id, "name": "\(id) (balanced)", "provider": provider, "isDefault": isDefault]
    }

    private func configureLoadResponses(_ fake: FakeConnectionManager) {
        fake.responseMap["specialist.list"] = ["specialists": [
            specialistDict(id: "implementor"),
            specialistDict(id: "coordinator", role: "orchestrator"),
        ]]
        fake.responseMap["host.providerAuthStatus"] = ["providers": [
            providerDict(id: "auggie", authenticated: true),
            providerDict(id: "claude-code", authenticated: false),
        ]]
        fake.responseMap["models.list"] = ["models": [modelDict(id: "sonnet4.5")]]
    }

    /// A fake whose reads answer immediately, plus a store that has
    /// completed its cold specialist/provider load over it.
    private func makeLoadedStore() async -> (store: CreationOptionsStore, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        return (store, fake)
    }

    /// Poll (bounded) until the condition holds — avoids fixed-sleep
    /// flakiness for assertions on Task-spawned background refreshes.
    /// Records a failure on timeout so a missed update cannot pass silently.
    private func waitFor(_ description: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(description)")
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
            ProviderInfo(id: "claude-code", authenticated: false),
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
        fake.responseMap["host.providerAuthStatus"] = ["providers": [
            providerDict(id: "auggie", authenticated: true),
            providerDict(id: "claude-code", authenticated: false),
            providerDict(id: "grok", authenticated: NSNull()),
            providerDict(id: "pi", authenticated: nil),
            ["authenticated": true],
        ]]
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        #expect(store.providers == [
            ProviderInfo(id: "auggie", authenticated: true),
            ProviderInfo(id: "claude-code", authenticated: false),
            ProviderInfo(id: "grok", authenticated: nil),
            ProviderInfo(id: "pi", authenticated: nil),
        ])
    }

    @Test func specialistsSkipUnparsableRows() async {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        fake.responseMap["specialist.list"] = ["specialists": [
            specialistDict(id: "implementor"),
            ["id": "broken"],
        ]]
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
        try await waitFor("refresh reads") { fake.paramsForMethod("specialist.list").count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)

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

        store.invalidate()
        #expect(store.specialists.isEmpty)
        #expect(store.hasLoaded == false)

        // The superseded refresh completes with data from before the
        // invalidation: it must not repopulate the cache or mark it loaded.
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "stale")]])
        try await Task.sleep(nanoseconds: 100_000_000)
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
        await store.loadIfNeeded()
        store.invalidate()

        try await Task.sleep(nanoseconds: 100_000_000)
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

    @Test func reconnectHardClearsCacheThenReloadsCold() async throws {
        let (store, fake) = await makeLoadedStore()
        await store.loadModelsIfNeeded(providerId: "auggie")
        fake.responseMap["specialist.list"] = ["specialists": [specialistDict(id: "fresh")]]
        // Hold the reload's reads so the cleared state is observable before
        // any fresh data lands.
        fake.pendingMethods = ["specialist.list", "host.providerAuthStatus"]
        fake.clearRequestLog()

        fake.simulateConnect()

        try await waitFor("reload reads") {
            fake.didCallMethod("specialist.list") && fake.didCallMethod("host.providerAuthStatus")
        }
        // Stale lists (models included) are gone before the reload answers;
        // the picker shows the cold loading state rather than a stale list.
        #expect(store.specialists.isEmpty)
        #expect(store.providers.isEmpty)
        #expect(store.models(for: "auggie") == nil)
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

    @Test func reconnectAfterFailedColdLoadClearsPartialCacheAndRetries() async throws {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        fake.errorMap["host.providerAuthStatus"] = NSError(domain: "t", code: -1)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        #expect(store.specialists.isEmpty == false)
        #expect(store.hasLoaded == false)

        fake.errorMap["host.providerAuthStatus"] = nil
        fake.clearRequestLog()

        fake.simulateConnect()

        // The reconnect still hard-clears the partial cache and retries.
        try await waitFor("retry completion") { store.hasLoaded }
        #expect(fake.paramsForMethod("specialist.list").count == 1)
        #expect(fake.paramsForMethod("host.providerAuthStatus").count == 1)
        #expect(store.providers.map(\.id) == ["auggie", "claude-code"])
        #expect(store.isLoading == false)
    }

    @Test func reconnectDoesNotJoinOrApplyPreReconnectRefresh() async throws {
        let (store, fake) = await makeLoadedStore()
        // A silent refresh whose specialist read is still in flight when the
        // connection flaps.
        fake.pendingMethods = ["specialist.list"]
        await store.loadIfNeeded()
        try await waitFor("pre-reconnect read") { fake.paramsForMethod("specialist.list").count == 2 }

        fake.simulateConnect()

        // The reconnect starts its own cold load instead of joining the
        // superseded flight, and the cache is already cleared.
        try await waitFor("reconnect read") { fake.paramsForMethod("specialist.list").count == 3 }
        #expect(store.specialists.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        // The pre-reconnect read resolves first (oldest pending) with stale
        // data: dropped.
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "stale")]])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.specialists.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        // The reconnect's own read lands.
        fake.resolvePending("specialist.list", with: ["specialists": [specialistDict(id: "fresh")]])
        try await waitFor("reconnect completion") { store.hasLoaded }
        #expect(store.specialists.map(\.id) == ["fresh"])
        #expect(store.isLoading == false)
    }

    /// A models-only consumer (the conversation menu, before any creation
    /// picker ran `loadIfNeeded`) still gets its catalog cleared on
    /// reconnect; the options lists are not fetched on its behalf.
    @Test func reconnectClearsModelsOnlyCacheWithoutLoadingOptions() async throws {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        fake.clearRequestLog()

        fake.simulateConnect()
        try await waitFor("model cache clear") { store.models(for: "auggie") == nil }
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.loadGeneration == 1)
        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)

        // The consumer's next ask runs cold and repopulates the catalog.
        fake.responseMap["models.list"] = ["models": [modelDict(id: "fresh")]]
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["fresh"])
        #expect(fake.paramsForMethod("models.list").count == 1)
        #expect(fake.didCallMethod("specialist.list") == false)
    }

    @Test func reconnectWithoutCacheDoesNotFetch() async throws {
        let fake = FakeConnectionManager()
        configureLoadResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)

        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)
    }

    // MARK: - Models (per provider)

    @Test func coldModelLoadFetchesAndCachesPerProvider() async {
        let (store, fake) = await makeLoadedStore()
        #expect(store.models(for: "auggie") == nil)

        await store.loadModelsIfNeeded(providerId: "auggie")

        let calls = fake.paramsForMethod("models.list")
        #expect(calls.count == 1)
        #expect(calls[0]["providerId"] as? String == "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(store.models(for: "auggie")?.first?.provider == "auggie")
        #expect(store.models(for: "codex") == nil)
        // Model loads never drive the picker's loading state.
        #expect(store.isLoading == false)
    }

    @Test func modelParsingFallsBackToRequestedProviderAndSkipsUnparsableRows() async {
        let (store, fake) = await makeLoadedStore()
        fake.responseMap["models.list"] = ["models": [
            ["id": "gpt-5", "name": "GPT-5"],
            ["id": "gpt-5-mini", "name": "GPT-5 mini", "provider": "codex", "isDefault": true],
            ["id": "no-name"],
        ]]

        await store.loadModelsIfNeeded(providerId: "codex")

        let models = store.models(for: "codex") ?? []
        #expect(models.map(\.id) == ["gpt-5", "gpt-5-mini"])
        #expect(models.map(\.provider) == ["codex", "codex"])
        #expect(models.map(\.isDefault) == [false, true])
    }

    @Test func cachedModelLoadReturnsImmediatelyAndRevalidatesSilently() async throws {
        let (store, fake) = await makeLoadedStore()
        await store.loadModelsIfNeeded(providerId: "auggie")
        fake.pendingMethods = ["models.list"]

        await store.loadModelsIfNeeded(providerId: "auggie")

        // Returned with the cached catalog intact while the refresh is in flight.
        try await waitFor("refresh read") { fake.paramsForMethod("models.list").count == 2 }
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(store.isLoading == false)

        fake.resolvePending("models.list", with: ["models": [modelDict(id: "opus4.6")]])
        try await waitFor("refresh completion") { store.models(for: "auggie")?.map(\.id) == ["opus4.6"] }
    }

    @Test func concurrentModelLoadsForOneProviderShareOneFlight() async throws {
        let (store, fake) = await makeLoadedStore()

        // Hold the reads open so every caller enters the store while the
        // first flight is still in flight (a completed flight would turn the
        // second call into a legitimate stale-while-revalidate refresh).
        fake.pendingMethods = ["models.list"]
        let first = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        let second = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        let other = Task { await store.loadModelsIfNeeded(providerId: "codex") }
        try await waitFor("both cold reads") { fake.paramsForMethod("models.list").count == 2 }
        fake.resolvePending("models.list", with: ["models": [modelDict(id: "sonnet4.5")]])
        fake.resolvePending("models.list", with: ["models": [modelDict(id: "gpt", provider: "codex")]])
        _ = await (first.value, second.value, other.value)

        let providerIds = fake.paramsForMethod("models.list").compactMap { $0["providerId"] as? String }
        #expect(providerIds.sorted() == ["auggie", "codex"])
        #expect(store.models(for: "auggie") != nil)
        #expect(store.models(for: "codex") != nil)
    }

    @Test func failedModelLoadKeepsCacheAndRetriesColdNextTime() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.errorMap["models.list"] = NSError(domain: "t", code: -1)

        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie") == nil)

        // Not cached after a failure: the next call is an awaited cold load.
        fake.errorMap["models.list"] = nil
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(fake.paramsForMethod("models.list").count == 2)

        // A failed background refresh keeps the cached catalog.
        fake.errorMap["models.list"] = NSError(domain: "t", code: -1)
        await store.loadModelsIfNeeded(providerId: "auggie")
        try await waitFor("refresh read") { fake.paramsForMethod("models.list").count == 3 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
    }

    @Test func invalidateDuringPendingModelLoadRejectsStaleCompletion() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.pendingMethods = ["models.list"]
        let load = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        try await waitFor("model read") { fake.didCallMethod("models.list") }

        store.invalidate()
        fake.resolvePending("models.list", with: ["models": [modelDict(id: "stale")]])
        await load.value
        #expect(store.models(for: "auggie") == nil)

        // The next call starts a fresh flight rather than joining the
        // superseded one.
        fake.pendingMethods = []
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(fake.paramsForMethod("models.list").count == 2)
    }
}
