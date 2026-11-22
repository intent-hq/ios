@testable import Intent
import SwiftUI
import Testing

extension CreateWorkspaceParamsTests {
    // MARK: - Create gate sequencing (per selected provider + store generation)

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

        await loadModels("auggie", store: store, settled: &settled)
        #expect(!catalogGate("auggie", store: store, settled: settled))

        #expect(catalogGate("codex", store: store, settled: settled))
        await loadModels("codex", store: store, settled: &settled)
        #expect(!catalogGate("codex", store: store, settled: settled))
        #expect(!catalogGate("auggie", store: store, settled: settled))
    }

    @MainActor
    @Test func providerSwitchWhileFirstLoadPendingKeepsCreateGatedUntilNewProviderSettles() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["models.list"]
        let store = CreationOptionsStore(connectionManager: fake)
        var settled = SpecialistPickerView.SettledLoads()

        let loadA = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        try await waitForModelsListCalls(fake, count: 1)
        let generationA = store.loadGeneration
        let loadB = Task { await store.loadModelsIfNeeded(providerId: "codex") }
        try await waitForModelsListCalls(fake, count: 2)
        let generationB = store.loadGeneration

        fake.resolvePending("models.list", with: ["models": [["id": "a", "name": "a", "provider": "auggie"]]])
        await loadA.value
        settled.settleModels(for: "auggie", startedAt: generationA, current: store.loadGeneration)
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

        store.invalidate()
        settled.reset()
        let freshGeneration = store.loadGeneration
        let freshLoad = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        try await waitForModelsListCalls(fake, count: 2)

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
        #expect(store.models(for: "auggie") == nil)
        #expect(!catalogGate("auggie", store: store, settled: settled))
        #expect(catalogGate("codex", store: store, settled: settled))

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
        #expect(CreationSelectionPolicy.reconciledModel(current: current, models: []) == nil)
    }

    @Test func reconciledModelDropsExplicitModelAcrossProviderSwitchWithSharedBareId() {
        let codexCatalog = [makeModel(id: "sonnet4.5", provider: "codex"), makeModel(id: "gpt-5", provider: "codex")]
        let auggieCatalog = [makeModel(id: "sonnet4.5", provider: "auggie")]
        #expect(codexCatalog.map(\.id).contains("sonnet4.5") && auggieCatalog.map(\.id).contains("sonnet4.5"))
        let pickedOnCodex = codexCatalog[0]
        #expect(CreationSelectionPolicy.reconciledModel(current: pickedOnCodex, models: auggieCatalog) == nil)
        #expect(CreationSelectionPolicy.reconciledModel(current: pickedOnCodex, models: codexCatalog) == pickedOnCodex)
    }

    // MARK: - isCreateDisabled (Create unavailable in the guidance state, monorepo#1003)

    @Test(arguments: [WorkspaceProviderOptions.State.idle, .loading])
    func pendingWorkspacePolicyKeepsDraftSelection(state: WorkspaceProviderOptions.State) {
        var provider: ProviderInfo? = makeProvider(id: "codex")
        var model: ModelInfo? = makeModel(id: "named-model", provider: "codex")
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: state)
        #expect(provider == makeProvider(id: "codex"))
        #expect(model == makeModel(id: "named-model", provider: "codex"))
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false, isLoadingProviders: true, providers: [], selectedProvider: provider
        ))
    }

    @Test func disabledWorkspaceProviderDropsItsExplicitModel() {
        var provider: ProviderInfo? = makeProvider(id: "codex")
        var model: ModelInfo? = makeModel(id: "shared-id", provider: "codex")
        CreationSelectionPolicy.reconcileWorkspaceProvider(
            provider: &provider, model: &model, state: .loaded([makeProvider()])
        )
        #expect(provider?.id == "auggie")
        #expect(model == nil)
        model = makeModel()
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: .loaded([]))
        #expect(provider == nil)
        #expect(model == nil)
        #expect(CreationSelectionPolicy.preselectedProvider(current: makeProvider(), providers: []) != nil)
    }

    @Test func unchangedWorkspaceProviderKeepsItsModelAndNilSelectionCannotSubmit() {
        var provider: ProviderInfo? = makeProvider()
        var model: ModelInfo? = makeModel()
        CreationSelectionPolicy.reconcileWorkspaceProvider(
            provider: &provider, model: &model, state: .loaded([makeProvider()])
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
        #expect(!isCreateDisabled(providers: [makeProvider(id: "grok", authenticated: .unknown)]))
    }

    @Test func createDisabledWhenProviderListEmptyAfterLoad() {
        #expect(isCreateDisabled(providers: []))
    }

    @Test func createDisabledWhileCreatingOrLoadingProviders() {
        #expect(isCreateDisabled(providers: [makeProvider()], isCreating: true))
        #expect(isCreateDisabled(providers: [], isLoadingProviders: true))
    }
}
