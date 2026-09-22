@testable import Intent
import SwiftUI
import Testing

extension CreateWorkspaceParamsTests {
    // MARK: - Create gate sequencing (per selected provider + store generation)

    /// The sheet's Create gate for `providerId`, exactly as
    /// `CreateWorkspaceView.isLoadingSelectedModelCatalog` derives it from
    /// the store's cache slot and the sheet's per-provider settled markers.
    @MainActor
    private func catalogGate(
        _ providerId: String,
        store: CreationOptionsStore,
        settled: SpecialistPickerView.SettledLoads
    ) -> Bool {
        CreateWorkspaceView.showsModelCatalogLoading(
            catalogCached: store.models(for: providerId) != nil,
            settled: settled.modelProviders.contains(providerId)
        )
    }

    /// Mirrors `CreateWorkspaceView.loadModels(for:)`: load, then settle
    /// only in the generation the load started in.
    @MainActor
    private func loadModels(
        _ providerId: String,
        store: CreationOptionsStore,
        settled: inout SpecialistPickerView.SettledLoads
    ) async {
        let generation = store.loadGeneration
        await store.loadModelsIfNeeded(providerId: providerId)
        settled.settleModels(for: providerId, startedAt: generation, current: store.loadGeneration)
    }

    @MainActor
    private func waitForModelsListCalls(_ fake: FakeConnectionManager, count: Int) async throws {
        let maximumPollAttempts = 200
        let pollIntervalNanoseconds: UInt64 = 10_000_000
        for _ in 0..<maximumPollAttempts where fake.paramsForMethod("models.list").count < count {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        #expect(fake.paramsForMethod("models.list").count == count)
    }

    @MainActor
    @Test func switchingToUncachedProviderReArmsCreateGateUntilItSettles() async {
        let fake = FakeConnectionManager()
        fake.responseMap["models.list"] = ["models": [["id": "m", "name": "m", "provider": "auggie"]]]
        let store = CreationOptionsStore(connectionManager: fake)
        var settled = SpecialistPickerView.SettledLoads()

        // Provider A settles: Create enabled for A.
        await loadModels("auggie", store: store, settled: &settled)
        #expect(!catalogGate("auggie", store: store, settled: settled))

        // The user picks uncached B: A's settlement must not enable Create
        // for B while B's catalog is unresolved.
        #expect(catalogGate("codex", store: store, settled: settled))
        await loadModels("codex", store: store, settled: &settled)
        #expect(!catalogGate("codex", store: store, settled: settled))
        // Switching back to the warm A is instant.
        #expect(!catalogGate("auggie", store: store, settled: settled))
    }

    @MainActor
    @Test func providerSwitchWhileFirstLoadPendingKeepsCreateGatedUntilNewProviderSettles() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["models.list"]
        let store = CreationOptionsStore(connectionManager: fake)
        var settled = SpecialistPickerView.SettledLoads()

        // A's load is in flight when the user picks B; A resolves first.
        let loadA = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        try await waitForModelsListCalls(fake, count: 1)
        let generationA = store.loadGeneration
        let loadB = Task { await store.loadModelsIfNeeded(providerId: "codex") }
        try await waitForModelsListCalls(fake, count: 2)
        let generationB = store.loadGeneration

        fake.resolvePending("models.list", with: ["models": [["id": "a", "name": "a", "provider": "auggie"]]])
        await loadA.value
        settled.settleModels(for: "auggie", startedAt: generationA, current: store.loadGeneration)
        // A settled, but B (the selection) is still unresolved: Create stays disabled.
        #expect(!catalogGate("auggie", store: store, settled: settled))
        #expect(catalogGate("codex", store: store, settled: settled))
        #expect(
            isCreateDisabled(
                providers: [makeProvider(id: "codex")],
                isLoadingProviders: catalogGate("codex", store: store, settled: settled)
            )
        )

        fake.resolvePending("models.list", with: ["models": [["id": "b", "name": "b", "provider": "codex"]]])
        await loadB.value
        settled.settleModels(for: "codex", startedAt: generationB, current: store.loadGeneration)
        #expect(!catalogGate("codex", store: store, settled: settled))
    }

    @MainActor
    @Test func reconnectDuringPendingCatalogLoadIgnoresOldSettlementAndReArmsGate() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["models.list"]
        let store = CreationOptionsStore(connectionManager: fake)
        var settled = SpecialistPickerView.SettledLoads()

        let oldGeneration = store.loadGeneration
        let oldLoad = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        try await waitForModelsListCalls(fake, count: 1)

        // Reconnect: the store hard-clears and the sheet drops its markers.
        store.invalidate()
        settled.reset()
        let freshGeneration = store.loadGeneration
        let freshLoad = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        try await waitForModelsListCalls(fake, count: 2)

        // The pre-reconnect request answers first: it settles nothing and
        // Create stays disabled on the still-pending fresh load.
        fake.resolvePending("models.list", with: ["models": [["id": "stale", "name": "stale", "provider": "auggie"]]])
        await oldLoad.value
        let oldPublished = settled.settleModels(
            for: "auggie",
            startedAt: oldGeneration,
            current: store.loadGeneration
        )
        #expect(!oldPublished)
        #expect(store.models(for: "auggie") == nil)
        #expect(catalogGate("auggie", store: store, settled: settled))

        // A failed fresh load still settles (daemon default), a success too.
        fake.resolvePending("models.list", with: ["models": [["id": "fresh", "name": "fresh", "provider": "auggie"]]])
        await freshLoad.value
        let freshPublished = settled.settleModels(
            for: "auggie",
            startedAt: freshGeneration,
            current: store.loadGeneration
        )
        #expect(freshPublished)
        #expect(store.models(for: "auggie")?.map(\.id) == ["fresh"])
        #expect(!catalogGate("auggie", store: store, settled: settled))
    }

    @MainActor
    @Test func failedCatalogLoadSettlesOnlyItsProviderAndGeneration() async {
        let fake = FakeConnectionManager()
        fake.errorMap["models.list"] = NSError(domain: "t", code: -1)
        let store = CreationOptionsStore(connectionManager: fake)
        var settled = SpecialistPickerView.SettledLoads()

        await loadModels("auggie", store: store, settled: &settled)
        // Failure settles A (daemon default, Create enabled) but not B.
        #expect(store.models(for: "auggie") == nil)
        #expect(!catalogGate("auggie", store: store, settled: settled))
        #expect(catalogGate("codex", store: store, settled: settled))

        // A reconnect re-arms A's gate until a fresh load for it settles.
        store.invalidate()
        settled.reset()
        #expect(catalogGate("auggie", store: store, settled: settled))
    }

    // MARK: - preselectedProvider

    @Test func preselectedProviderPrefersSelectableAuggieThenFirstSelectable() {
        let providers = [
            makeProvider(id: "codex", authenticated: .signedIn),
            makeProvider(id: "auggie", authenticated: .signedIn)
        ]
        #expect(CreationSelectionPolicy.preselectedProvider(current: nil, providers: providers)?.id == "auggie")
        let auggieSignedOut = [
            makeProvider(id: "auggie", authenticated: .signedOut),
            makeProvider(id: "grok", authenticated: .unknown),
            makeProvider(id: "codex", authenticated: .signedIn)
        ]
        // nil (unknown) stays selectable since probes can fail transiently
        #expect(
            CreationSelectionPolicy.preselectedProvider(
                current: nil,
                providers: auggieSignedOut
            )?.id == "grok"
        )
    }

    @Test func preselectedProviderKeepsStillSelectableSelectionAndRedefaultsWhenNot() {
        let providers = [
            makeProvider(id: "auggie", authenticated: .signedIn),
            makeProvider(id: "codex", authenticated: .signedIn)
        ]
        #expect(
            CreationSelectionPolicy.preselectedProvider(
                current: makeProvider(id: "codex"),
                providers: providers
            )?.id == "codex"
        )
        // The selected provider signed out under a background refresh.
        let codexSignedOut = [
            makeProvider(id: "auggie", authenticated: .signedIn),
            makeProvider(id: "codex", authenticated: .signedOut)
        ]
        #expect(
            CreationSelectionPolicy.preselectedProvider(
                current: makeProvider(id: "codex"),
                providers: codexSignedOut
            )?.id == "auggie"
        )
    }

    @Test func preselectedProviderRebindsSurvivingSelectionAndEqualityTracksAuth() {
        // Same provider ids, auth state changed: the arrays compare unequal
        // (so the observer fires) and the kept selection carries the fresh
        // tri-state rather than the stale DTO.
        let cached = [
            makeProvider(id: "auggie", authenticated: .signedIn),
            makeProvider(id: "codex", authenticated: .unknown)
        ]
        let refreshed = [
            makeProvider(id: "auggie", authenticated: .signedIn),
            makeProvider(id: "codex", authenticated: .signedIn)
        ]
        #expect(cached.map(\.id) == refreshed.map(\.id))
        #expect(cached != refreshed)
        let kept = CreationSelectionPolicy.preselectedProvider(current: cached[1], providers: refreshed)
        #expect(kept == refreshed[1])
        #expect(kept?.authenticated == true)
    }

    @Test func preselectedProviderIsNilWhenNoneSelectableAndKeepsSelectionAcrossAnEmptyList() {
        let allSignedOut = [
            makeProvider(id: "auggie", authenticated: .signedOut),
            makeProvider(id: "codex", authenticated: .signedOut)
        ]
        #expect(
            CreationSelectionPolicy.preselectedProvider(
                current: makeProvider(id: "codex"),
                providers: allSignedOut
            ) == nil
        )
        #expect(
            CreationSelectionPolicy.preselectedProvider(
                current: makeProvider(id: "codex"),
                providers: []
            )?.id == "codex"
        )
        #expect(CreationSelectionPolicy.preselectedProvider(current: nil, providers: []) == nil)
    }

    // MARK: - reconciledModel (explicit model vs. the displayed catalog)

    @Test func reconciledModelKeepsAndRebindsWhileStillListedForSameProvider() {
        let refreshed = [
            makeModel(id: "sonnet4.5", provider: "auggie"),
            ModelInfo(id: "opus4.6", name: "opus4.6 (renamed)", provider: "auggie", isDefault: true)
        ]
        let kept = CreationSelectionPolicy.reconciledModel(
            current: makeModel(id: "opus4.6", provider: "auggie"),
            models: refreshed
        )
        #expect(kept == refreshed[1])
        #expect(kept?.name == "opus4.6 (renamed)")
        #expect(CreationSelectionPolicy.reconciledModel(current: nil, models: refreshed) == nil)
    }

    @Test func reconciledModelDropsRetiredOrClearedCatalogEntries() {
        let current = makeModel(id: "opus4.6", provider: "auggie")
        #expect(
            CreationSelectionPolicy.reconciledModel(
                current: current,
                models: [makeModel(id: "sonnet4.5", provider: "auggie")]
            ) == nil
        )
        // Reconnect clear / catalog not loaded yet: daemon default applies.
        #expect(CreationSelectionPolicy.reconciledModel(current: current, models: []) == nil)
    }

    @Test func reconciledModelDropsExplicitModelAcrossProviderSwitchWithSharedBareId() {
        // Two cached provider catalogs share a bare model id. After an
        // automatic provider switch the old explicit pick must not survive
        // into the new provider's catalog: the daemon default applies.
        let codexCatalog = [makeModel(id: "sonnet4.5", provider: "codex"), makeModel(id: "gpt-5", provider: "codex")]
        let auggieCatalog = [makeModel(id: "sonnet4.5", provider: "auggie")]
        #expect(codexCatalog.map(\.id).contains("sonnet4.5") && auggieCatalog.map(\.id).contains("sonnet4.5"))
        let pickedOnCodex = codexCatalog[0]
        #expect(CreationSelectionPolicy.reconciledModel(current: pickedOnCodex, models: auggieCatalog) == nil)
        // Staying on the same provider keeps it.
        #expect(CreationSelectionPolicy.reconciledModel(current: pickedOnCodex, models: codexCatalog) == pickedOnCodex)
    }

    // MARK: - isCreateDisabled (Create unavailable in the guidance state, monorepo#1003)

    @Test func disabledWorkspaceProviderDropsItsExplicitModel() {
        var provider: ProviderInfo? = makeProvider(id: "codex")
        var model: ModelInfo? = makeModel(id: "shared-id", provider: "codex")
        CreationSelectionPolicy.reconcileWorkspaceProvider(
            provider: &provider, model: &model, providers: [makeProvider()]
        )
        #expect(provider?.id == "auggie")
        #expect(model == nil)
        model = makeModel()
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, providers: [])
        #expect(provider == nil)
        #expect(model == nil)
        // Agent creation intentionally retains its prior empty-list policy.
        #expect(CreationSelectionPolicy.preselectedProvider(current: makeProvider(), providers: []) != nil)
    }

    @Test func unchangedWorkspaceProviderKeepsItsModelAndNilSelectionCannotSubmit() {
        var provider: ProviderInfo? = makeProvider()
        var model: ModelInfo? = makeModel()
        CreationSelectionPolicy.reconcileWorkspaceProvider(
            provider: &provider, model: &model, providers: [makeProvider()]
        )
        #expect(model == makeModel())
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false, isLoadingProviders: false, providers: [makeProvider()], selectedProvider: nil
        ))
    }

    func isCreateDisabled(
        providers: [ProviderInfo],
        isCreating: Bool = false,
        isLoadingProviders: Bool = false
    ) -> Bool {
        CreateWorkspaceView.isCreateDisabled(
            isCreating: isCreating,
            isLoadingProviders: isLoadingProviders,
            providers: providers,
            selectedProvider: providers.first(where: \.isSelectable)
        )
    }

    @Test func createDisabledWhenNoProviderSelectable() {
        let providers = [
            makeProvider(id: "auggie", authenticated: .signedOut),
            makeProvider(id: "codex", authenticated: .signedOut)
        ]
        #expect(isCreateDisabled(providers: providers))
    }

    @Test func createEnabledWhenAProviderIsSelectable() {
        #expect(!isCreateDisabled(providers: [makeProvider()]))
        // nil (unknown) stays selectable since probes can fail transiently
        #expect(!isCreateDisabled(providers: [makeProvider(id: "grok", authenticated: .unknown)]))
    }

    @Test func createDisabledWhenProviderListEmptyAfterLoad() {
        // An empty enabled set must never submit the daemon's fallback provider.
        #expect(isCreateDisabled(providers: []))
    }

    @Test func createDisabledWhileCreatingOrLoadingProviders() {
        #expect(isCreateDisabled(providers: [makeProvider()], isCreating: true))
        // An empty in-flight list can't be told apart from a seat with no providers
        #expect(isCreateDisabled(providers: [], isLoadingProviders: true))
    }
}
