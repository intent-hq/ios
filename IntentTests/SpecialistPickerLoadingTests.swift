import Foundation
@testable import Intent
import Testing

extension SpecialistPickerSelectionTests {
    private static let maximumPollAttempts = 200
    private static let pollIntervalNanoseconds: UInt64 = 10_000_000

    private struct ReconnectRace {
        let oldGeneration: Int
        let oldLoad: Task<Void, Never>
        let settled: SpecialistPickerView.SettledLoads
    }

    // MARK: - Loading states against the session store (cached vs. cold path)

    private func configureStoreResponses(_ fake: FakeConnectionManager) {
        fake.responseMap["specialist.list"] = [
            "specialists": [
                ["id": "implementor", "name": "Implementor", "description": "d"],
                ["id": "coordinator", "name": "Coordinator", "description": "d", "role": "orchestrator"]
            ]
        ]
        fake.responseMap["host.providerAuthStatus"] = [
            "providers": [
                ["id": "auggie", "authenticated": true],
                ["id": "claude-code", "authenticated": false]
            ]
        ]
        fake.responseMap["models.list"] = [
            "models": [
                ["id": "sonnet4.5", "name": "sonnet4.5", "provider": "auggie", "isDefault": true]
            ]
        ]
    }

    @MainActor
    @Test func cachedStoreRendersSpecialistsProvidersAndModelsWithoutLoading() async {
        let fake = FakeConnectionManager()
        configureStoreResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        // A previous sheet (or the New Workspace flow) warmed the cache.
        await store.loadIfNeeded()
        await store.loadModelsIfNeeded(providerId: "auggie")
        fake.clearRequestLog()

        // A reopened sheet before its own load settles: no spinner on either
        // step, and the selections resolve synchronously from the cache.
        #expect(
            !CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: store.isLoading,
                storeHasLoaded: store.hasLoaded,
                settled: false
            )
        )
        #expect(
            SpecialistPickerView.reconciledSpecialist(
                current: nil,
                catalog: store.specialists
            )?.id == "coordinator"
        )
        let provider = CreateWorkspaceView.preselectedProvider(current: nil, providers: store.providers)
        #expect(provider?.id == "auggie")
        #expect(!SpecialistPickerView.showsModelsLoading(catalog: store.models(for: "auggie"), settled: false))
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(
            !SpecialistPickerView.isCreateDisabled(
                hasSpecialist: true,
                isCreating: false,
                isLoadingProviders: false,
                isLoadingModels: false,
                providers: store.providers
            )
        )
        // Nothing was fetched to render the cached lists.
        #expect(fake.requestLog.isEmpty)
    }

    @MainActor
    @Test func coldStoreShowsLoadingUntilSettledThenReconciles() async {
        let fake = FakeConnectionManager()
        configureStoreResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)

        // First open in the session: nothing cached, both steps spin and
        // Create stays disabled.
        #expect(
            CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: store.isLoading,
                storeHasLoaded: store.hasLoaded,
                settled: false
            )
        )
        #expect(SpecialistPickerView.reconciledSpecialist(current: nil, catalog: store.specialists) == nil)
        #expect(SpecialistPickerView.showsModelsLoading(catalog: store.models(for: "auggie"), settled: false))
        #expect(
            SpecialistPickerView.isCreateDisabled(
                hasSpecialist: false,
                isCreating: false,
                isLoadingProviders: true,
                isLoadingModels: true,
                providers: store.providers
            )
        )

        await store.loadIfNeeded()
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(
            !CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: store.isLoading,
                storeHasLoaded: store.hasLoaded,
                settled: true
            )
        )
        #expect(
            SpecialistPickerView.reconciledSpecialist(
                current: nil,
                catalog: store.specialists
            )?.id == "coordinator"
        )
        #expect(!SpecialistPickerView.showsModelsLoading(catalog: store.models(for: "auggie"), settled: true))
        #expect(fake.paramsForMethod("specialist.list").count == 1)
        #expect(fake.paramsForMethod("models.list").count == 1)
    }

    @MainActor
    @Test func failedColdModelLoadSettlesToDaemonDefaultInsteadOfSpinning() async {
        let fake = FakeConnectionManager()
        configureStoreResponses(fake)
        fake.errorMap["models.list"] = URLError(.notConnectedToInternet)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()

        await store.loadModelsIfNeeded(providerId: "auggie")
        // The catalog stays uncached, but the sheet's load settled: the
        // Model section shows the daemon-default row and Create is enabled
        // rather than wedged behind "Loading models...".
        #expect(store.models(for: "auggie") == nil)
        #expect(!SpecialistPickerView.showsModelsLoading(catalog: store.models(for: "auggie"), settled: true))
        #expect(
            !SpecialistPickerView.isCreateDisabled(
                hasSpecialist: true,
                isCreating: false,
                isLoadingProviders: false,
                isLoadingModels: false,
                providers: store.providers
            )
        )
    }

    @MainActor
    @Test func olderProviderResponseNeverPresentsAsNewerSelectionsCatalog() async throws {
        let fake = FakeConnectionManager()
        configureStoreResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()

        // The user picks grok (slow), then auggie (fast): the picker derives
        // `models` from the selected provider's cache slot, so grok's late
        // response can only land under "grok" and never as auggie's list.
        fake.pendingMethods = ["models.list"]
        let grokLoad = Task { await store.loadModelsIfNeeded(providerId: "grok") }
        for _ in 0..<200 where fake.paramsForMethod("models.list").isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fake.paramsForMethod("models.list").count == 1)
        fake.pendingMethods = []
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(store.models(for: "grok") == nil)

        fake.resolvePending(
            "models.list",
            with: [
                "models": [
                    ["id": "grok-4", "name": "grok-4", "provider": "grok"]
                ]
            ]
        )
        await grokLoad.value

        let auggieModels = store.models(for: "auggie") ?? []
        #expect(auggieModels.map(\.id) == ["sonnet4.5"])
        #expect(store.models(for: "grok")?.map(\.id) == ["grok-4"])
        // An explicit grok pick does not survive the switch to auggie even
        // if a bare id were shared: reconciliation matches id and provider.
        let stalePick = makeModel("grok-4", provider: "grok")
        #expect(CreateWorkspaceView.reconciledModel(current: stalePick, models: auggieModels) == nil)
    }

    /// Holds the sheet's auggie load, reconnects (hard clear), starts the
    /// fresh same-provider load, and returns the OLD request first while the
    /// fresh one stays held.
    @MainActor
    private func makeReconnectRace(
        _ fake: FakeConnectionManager,
        store: CreationOptionsStore
    ) async throws -> ReconnectRace {
        await store.loadIfNeeded()
        var settled = SpecialistPickerView.SettledLoads()
        fake.pendingMethods = ["models.list"]
        let oldGeneration = store.loadGeneration
        let oldLoad = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        for _ in 0..<Self.maximumPollAttempts where fake.paramsForMethod("models.list").isEmpty {
            try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
        #expect(fake.paramsForMethod("models.list").count == 1)

        store.invalidate()
        settled.reset()
        return ReconnectRace(oldGeneration: oldGeneration, oldLoad: oldLoad, settled: settled)
    }

    @MainActor
    private func assertSupersededLoadDoesNotSettle(
        store: CreationOptionsStore,
        oldGeneration: Int,
        settled: inout SpecialistPickerView.SettledLoads
    ) {
        let oldPublished = settled.settleModels(
            for: "auggie",
            startedAt: oldGeneration,
            current: store.loadGeneration
        )
        #expect(!oldPublished)
        #expect(store.models(for: "auggie") == nil)
        let loadingAfterOld = SpecialistPickerView.showsModelsLoading(
            catalog: store.models(for: "auggie"),
            settled: settled.modelProviders.contains("auggie")
        )
        #expect(loadingAfterOld)
        #expect(
            SpecialistPickerView.isCreateDisabled(
                hasSpecialist: true,
                isCreating: false,
                isLoadingProviders: false,
                isLoadingModels: loadingAfterOld,
                providers: store.providers
            )
        )
    }

    @MainActor
    @Test func supersededModelLoadCannotSettleCurrentLoadingAfterReconnect() async throws {
        let fake = FakeConnectionManager()
        configureStoreResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        let race = try await makeReconnectRace(fake, store: store)
        let (oldGeneration, oldLoad) = (race.oldGeneration, race.oldLoad)
        var settled = race.settled

        let freshGeneration = store.loadGeneration
        let freshLoad = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        for _ in 0..<Self.maximumPollAttempts where fake.paramsForMethod("models.list").count < 2 {
            try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
        #expect(fake.paramsForMethod("models.list").count == 2)

        // The old request answers first: the store drops its catalog, and
        // the sheet must not settle on it — the Model section keeps loading
        // (Create disabled) until the fresh request answers.
        fake.resolvePending(
            "models.list",
            with: [
                "models": [
                    ["id": "stale", "name": "stale", "provider": "auggie"]
                ]
            ]
        )
        await oldLoad.value
        assertSupersededLoadDoesNotSettle(
            store: store,
            oldGeneration: oldGeneration,
            settled: &settled
        )

        fake.resolvePending(
            "models.list",
            with: [
                "models": [
                    ["id": "sonnet4.5", "name": "sonnet4.5", "provider": "auggie", "isDefault": true]
                ]
            ]
        )
        await freshLoad.value
        let freshPublished = settled.settleModels(
            for: "auggie",
            startedAt: freshGeneration,
            current: store.loadGeneration
        )
        #expect(freshPublished)
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(
            !SpecialistPickerView.showsModelsLoading(
                catalog: store.models(for: "auggie"),
                settled: settled.modelProviders.contains("auggie")
            )
        )
    }

    @MainActor
    @Test func freshModelLoadFailureSettlesAfterReconnectWhileOldCompletionDoesNot() async throws {
        let fake = FakeConnectionManager()
        configureStoreResponses(fake)
        let store = CreationOptionsStore(connectionManager: fake)
        let race = try await makeReconnectRace(fake, store: store)
        let (oldGeneration, oldLoad) = (race.oldGeneration, race.oldLoad)
        var settled = race.settled

        // The fresh request fails outright: the sheet's current load settled,
        // so the Model section shows the daemon-default row rather than
        // spinning on a catalog that will not arrive.
        fake.pendingMethods = []
        fake.errorMap["models.list"] = URLError(.notConnectedToInternet)
        let freshGeneration = store.loadGeneration
        await store.loadModelsIfNeeded(providerId: "auggie")
        let freshPublished = settled.settleModels(
            for: "auggie",
            startedAt: freshGeneration,
            current: store.loadGeneration
        )
        #expect(freshPublished)
        #expect(store.models(for: "auggie") == nil)
        #expect(
            !SpecialistPickerView.showsModelsLoading(
                catalog: store.models(for: "auggie"),
                settled: settled.modelProviders.contains("auggie")
            )
        )

        // The old request answering later changes nothing: its catalog is
        // dropped and its marker is not published.
        fake.resolvePending(
            "models.list",
            with: [
                "models": [
                    ["id": "stale", "name": "stale", "provider": "auggie"]
                ]
            ]
        )
        await oldLoad.value
        let oldPublished = settled.settleModels(
            for: "auggie",
            startedAt: oldGeneration,
            current: store.loadGeneration
        )
        #expect(!oldPublished)
        #expect(store.models(for: "auggie") == nil)
    }
}
