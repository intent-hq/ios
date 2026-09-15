import Foundation
import Testing
@testable import Intent

/// Tests for the SpecialistPickerView selection helpers: specialist
/// reconciliation against the cached catalog, the loading states derived
/// from `CreationOptionsStore` (cached and cold paths), and the
/// provider/model params sent on agent.create. Provider defaulting and
/// model reconciliation reuse `CreateWorkspaceView`'s helpers (covered in
/// `CreateWorkspaceParamsTests`).
struct SpecialistPickerSelectionTests {
    private func makeSpecialist(resolvedModel: String? = nil, resolvedProvider: String? = nil) -> SpecialistInfo {
        SpecialistInfo(
            id: "implementor", name: "Implementor", description: "Implements tasks",
            resolvedModel: resolvedModel, resolvedProvider: resolvedProvider
        )
    }

    private func makeCatalogSpecialist(
        id: String, name: String, hidden: Bool = false, role: String? = nil
    ) -> SpecialistInfo {
        SpecialistInfo(id: id, name: name, description: "", hidden: hidden, role: role)
    }

    private func makeModel(_ id: String, provider: String = "auggie", isDefault: Bool = false) -> ModelInfo {
        ModelInfo(id: id, name: id, provider: provider, isDefault: isDefault)
    }

    // MARK: - isSelectable

    @Test func unauthenticatedProvidersAreNotSelectable() {
        #expect(SpecialistPickerView.isSelectable(ProviderInfo(id: "auggie", authenticated: true)))
        #expect(SpecialistPickerView.isSelectable(ProviderInfo(id: "grok", authenticated: nil)))
        #expect(!SpecialistPickerView.isSelectable(ProviderInfo(id: "codex", authenticated: false)))
    }

    // MARK: - reconciledSpecialist (cached catalog → New Agent selection)

    @Test func reconciledSpecialistDefaultsToOrchestratorElseFirstInDaemonOrder() {
        let withOrchestrator = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier"),
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator"),
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(
            current: nil, catalog: withOrchestrator)?.id == "coordinator")
        // No orchestrator: the first pickable specialist as the daemon lists
        // it, not by name (the picker shows daemon order).
        let plain = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor"),
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(current: nil, catalog: plain)?.id == "verifier")
    }

    @Test func reconciledSpecialistSkipsHiddenAndInternalDefaults() {
        let catalog = [
            makeCatalogSpecialist(id: "secret", name: "Secret", hidden: true),
            makeCatalogSpecialist(id: "helper", name: "Helper", role: "internal"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor"),
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(current: nil, catalog: catalog)?.id == "implementor")
    }

    @Test func reconciledSpecialistRebindsSurvivingSelectionToFreshMetadata() {
        let current = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        var fresh = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        fresh.resolvedModel = "sonnet4.5"
        let catalog = [
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator"),
            fresh,
        ]
        let reconciled = SpecialistPickerView.reconciledSpecialist(current: current, catalog: catalog)
        #expect(reconciled?.id == "implementor")
        #expect(reconciled?.resolvedModel == "sonnet4.5")
    }

    @Test func reconciledSpecialistRedefaultsWhenSelectionGoneOrHidden() {
        let current = makeCatalogSpecialist(id: "verifier", name: "Verifier")
        let gone = [
            makeCatalogSpecialist(id: "implementor", name: "Implementor"),
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator"),
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(current: current, catalog: gone)?.id == "coordinator")
        // Same ids, but the selection turned hidden under a refresh: a
        // hidden id must never be submitted.
        let hidden = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier", hidden: true),
            makeCatalogSpecialist(id: "implementor", name: "Implementor"),
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(current: current, catalog: hidden)?.id == "implementor")
    }

    @Test func reconciledSpecialistClearsWhenNothingPickableAndKeepsSelectionAcrossEmptyCatalog() {
        let current = makeCatalogSpecialist(id: "verifier", name: "Verifier")
        let nonePickable = [makeCatalogSpecialist(id: "verifier", name: "Verifier", hidden: true)]
        #expect(SpecialistPickerView.reconciledSpecialist(current: current, catalog: nonePickable) == nil)
        // A reconnect clear (or cold load) empties the catalog: the
        // selection survives until the reload answers.
        #expect(SpecialistPickerView.reconciledSpecialist(current: current, catalog: [])?.id == "verifier")
        #expect(SpecialistPickerView.reconciledSpecialist(current: nil, catalog: []) == nil)
    }

    // MARK: - showsModelsLoading (cached catalog never spins; failed cold load settles)

    @Test func showsModelsLoadingOnlyWhileCatalogUncachedAndUnsettled() {
        #expect(SpecialistPickerView.showsModelsLoading(catalog: nil, settled: false))
        #expect(!SpecialistPickerView.showsModelsLoading(catalog: nil, settled: true))
        #expect(!SpecialistPickerView.showsModelsLoading(catalog: [], settled: false))
        #expect(!SpecialistPickerView.showsModelsLoading(catalog: [makeModel("sonnet4.5")], settled: false))
    }

    // MARK: - SettledLoads (generation-gated sheet markers)

    @Test func settledLoadsPublishOnlyForTheGenerationTheLoadStartedIn() {
        var settled = SpecialistPickerView.SettledLoads()
        #expect(!settled.settleOptions(startedAt: 0, current: 1))
        #expect(!settled.settleModels(for: "auggie", startedAt: 0, current: 1))
        #expect(!settled.options)
        #expect(settled.modelProviders.isEmpty)

        #expect(settled.settleOptions(startedAt: 1, current: 1))
        #expect(settled.settleModels(for: "auggie", startedAt: 1, current: 1))
        #expect(settled.options)
        #expect(settled.modelProviders == ["auggie"])

        settled.reset()
        #expect(!settled.options)
        #expect(settled.modelProviders.isEmpty)
    }

    // MARK: - Loading states against the session store (cached vs. cold path)

    private func configureStoreResponses(_ fake: FakeConnectionManager) {
        fake.responseMap["specialist.list"] = ["specialists": [
            ["id": "implementor", "name": "Implementor", "description": "d"],
            ["id": "coordinator", "name": "Coordinator", "description": "d", "role": "orchestrator"],
        ]]
        fake.responseMap["host.providerAuthStatus"] = ["providers": [
            ["id": "auggie", "authenticated": true],
            ["id": "claude-code", "authenticated": false],
        ]]
        fake.responseMap["models.list"] = ["models": [
            ["id": "sonnet4.5", "name": "sonnet4.5", "provider": "auggie", "isDefault": true],
        ]]
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
        #expect(!CreateWorkspaceView.showsOptionsLoading(
            storeIsLoading: store.isLoading, storeHasLoaded: store.hasLoaded, settled: false))
        #expect(SpecialistPickerView.reconciledSpecialist(
            current: nil, catalog: store.specialists)?.id == "coordinator")
        let provider = CreateWorkspaceView.preselectedProvider(current: nil, providers: store.providers)
        #expect(provider?.id == "auggie")
        #expect(!SpecialistPickerView.showsModelsLoading(catalog: store.models(for: "auggie"), settled: false))
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(!SpecialistPickerView.isCreateDisabled(
            hasSpecialist: true, isCreating: false, isLoadingProviders: false,
            isLoadingModels: false, providers: store.providers))
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
        #expect(CreateWorkspaceView.showsOptionsLoading(
            storeIsLoading: store.isLoading, storeHasLoaded: store.hasLoaded, settled: false))
        #expect(SpecialistPickerView.reconciledSpecialist(current: nil, catalog: store.specialists) == nil)
        #expect(SpecialistPickerView.showsModelsLoading(catalog: store.models(for: "auggie"), settled: false))
        #expect(SpecialistPickerView.isCreateDisabled(
            hasSpecialist: false, isCreating: false, isLoadingProviders: true,
            isLoadingModels: true, providers: store.providers))

        await store.loadIfNeeded()
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(!CreateWorkspaceView.showsOptionsLoading(
            storeIsLoading: store.isLoading, storeHasLoaded: store.hasLoaded, settled: true))
        #expect(SpecialistPickerView.reconciledSpecialist(
            current: nil, catalog: store.specialists)?.id == "coordinator")
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
        #expect(!SpecialistPickerView.isCreateDisabled(
            hasSpecialist: true, isCreating: false, isLoadingProviders: false,
            isLoadingModels: false, providers: store.providers))
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

        fake.resolvePending("models.list", with: ["models": [
            ["id": "grok-4", "name": "grok-4", "provider": "grok"],
        ]])
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
        _ fake: FakeConnectionManager, store: CreationOptionsStore
    ) async throws -> (oldGeneration: Int, oldLoad: Task<Void, Never>, settled: SpecialistPickerView.SettledLoads) {
        await store.loadIfNeeded()
        var settled = SpecialistPickerView.SettledLoads()
        fake.pendingMethods = ["models.list"]
        let oldGeneration = store.loadGeneration
        let oldLoad = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        for _ in 0..<200 where fake.paramsForMethod("models.list").isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fake.paramsForMethod("models.list").count == 1)

        store.invalidate()
        settled.reset()
        return (oldGeneration, oldLoad, settled)
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
        for _ in 0..<200 where fake.paramsForMethod("models.list").count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fake.paramsForMethod("models.list").count == 2)

        // The old request answers first: the store drops its catalog, and
        // the sheet must not settle on it — the Model section keeps loading
        // (Create disabled) until the fresh request answers.
        fake.resolvePending("models.list", with: ["models": [
            ["id": "stale", "name": "stale", "provider": "auggie"],
        ]])
        await oldLoad.value
        #expect(!settled.settleModels(for: "auggie", startedAt: oldGeneration, current: store.loadGeneration))
        #expect(store.models(for: "auggie") == nil)
        let loadingAfterOld = SpecialistPickerView.showsModelsLoading(
            catalog: store.models(for: "auggie"), settled: settled.modelProviders.contains("auggie"))
        #expect(loadingAfterOld)
        #expect(SpecialistPickerView.isCreateDisabled(
            hasSpecialist: true, isCreating: false, isLoadingProviders: false,
            isLoadingModels: loadingAfterOld, providers: store.providers))

        fake.resolvePending("models.list", with: ["models": [
            ["id": "sonnet4.5", "name": "sonnet4.5", "provider": "auggie", "isDefault": true],
        ]])
        await freshLoad.value
        #expect(settled.settleModels(for: "auggie", startedAt: freshGeneration, current: store.loadGeneration))
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(!SpecialistPickerView.showsModelsLoading(
            catalog: store.models(for: "auggie"), settled: settled.modelProviders.contains("auggie")))
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
        #expect(settled.settleModels(for: "auggie", startedAt: freshGeneration, current: store.loadGeneration))
        #expect(store.models(for: "auggie") == nil)
        #expect(!SpecialistPickerView.showsModelsLoading(
            catalog: store.models(for: "auggie"), settled: settled.modelProviders.contains("auggie")))

        // The old request answering later changes nothing: its catalog is
        // dropped and its marker is not published.
        fake.resolvePending("models.list", with: ["models": [
            ["id": "stale", "name": "stale", "provider": "auggie"],
        ]])
        await oldLoad.value
        #expect(!settled.settleModels(for: "auggie", startedAt: oldGeneration, current: store.loadGeneration))
        #expect(store.models(for: "auggie") == nil)
    }

    // MARK: - noneSelectable (desktop-setup guidance state, monorepo#985)

    @Test func noneSelectableWhenAllProvidersSignedOut() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "codex", authenticated: false),
        ]
        #expect(providers.noneSelectable)
    }

    @Test func notNoneSelectableWhenEmpty() {
        #expect(![ProviderInfo]().noneSelectable)
    }

    @Test func notNoneSelectableWhenAnyProviderSelectable() {
        let signedIn = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "claude-code", authenticated: true),
        ]
        #expect(!signedIn.noneSelectable)

        // nil (unknown) stays selectable since probes can fail transiently
        let unknown = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "grok", authenticated: nil),
        ]
        #expect(!unknown.noneSelectable)
    }

    // MARK: - isCreateDisabled (Create unavailable in the guidance state, monorepo#1003)

    private func isCreateDisabled(
        hasSpecialist: Bool = true,
        isCreating: Bool = false,
        isLoadingProviders: Bool = false,
        isLoadingModels: Bool = false,
        providers: [ProviderInfo]
    ) -> Bool {
        SpecialistPickerView.isCreateDisabled(
            hasSpecialist: hasSpecialist,
            isCreating: isCreating,
            isLoadingProviders: isLoadingProviders,
            isLoadingModels: isLoadingModels,
            providers: providers
        )
    }

    @Test func createDisabledWhenNoProviderSelectable() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "codex", authenticated: false),
        ]
        #expect(isCreateDisabled(providers: providers))
    }

    @Test func createEnabledWhenAProviderIsSelectable() {
        #expect(!isCreateDisabled(providers: [ProviderInfo(id: "auggie", authenticated: true)]))
        // nil (unknown) stays selectable since probes can fail transiently
        #expect(!isCreateDisabled(providers: [ProviderInfo(id: "grok", authenticated: nil)]))
    }

    @Test func createEnabledWhenProviderListEmpty() {
        // Empty list is not the guidance state: the daemon default is used
        #expect(!isCreateDisabled(providers: []))
    }

    @Test func createDisabledWhileLoadingCreatingOrWithoutSpecialist() {
        let providers = [ProviderInfo(id: "auggie", authenticated: true)]
        #expect(isCreateDisabled(hasSpecialist: false, providers: providers))
        #expect(isCreateDisabled(isCreating: true, providers: providers))
        #expect(isCreateDisabled(isLoadingProviders: true, providers: providers))
        #expect(isCreateDisabled(isLoadingModels: true, providers: providers))
    }

    // MARK: - daemonDefaultLabel (resolvedModel/resolvedProvider preview)

    @Test func daemonDefaultLabelNamesResolvedModelForMatchingProvider() {
        let specialist = makeSpecialist(resolvedModel: "sonnet4.5", resolvedProvider: "auggie")
        #expect(SpecialistInfo.daemonDefaultLabel(for: specialist, providerId: "auggie") == "Default (sonnet4.5)")
    }

    @Test func daemonDefaultLabelFallsBackWhenProviderContextDiffers() {
        // The preview was resolved for another provider; its model must not
        // be shown as the default for the selected one.
        let specialist = makeSpecialist(resolvedModel: "sonnet4.5", resolvedProvider: "auggie")
        #expect(SpecialistInfo.daemonDefaultLabel(for: specialist, providerId: "claude-code") == "Provider default")
    }

    @Test func daemonDefaultLabelFallsBackWhenFieldsOmitted() {
        // Omitted fields mean resolution yielded the provider CLI default.
        #expect(SpecialistInfo.daemonDefaultLabel(for: makeSpecialist(), providerId: "auggie") == "Provider default")
        #expect(SpecialistInfo.daemonDefaultLabel(for: nil, providerId: "auggie") == "Provider default")
    }

    // MARK: - buildCreateAgentSelection

    @Test func omitsBothOnDaemonDefaultSelection() {
        // No explicit user pick: the daemon's resolver decides the model.
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            provider: ProviderInfo(id: "auggie", authenticated: true),
            model: nil
        )
        #expect(selection.provider == nil)
        #expect(selection.model == nil)
    }

    @Test func sendsModelOnlyOnExplicitAuggiePick() {
        // Auggie is the daemon default, so the provider is omitted and only
        // the bare model pick is sent — matching CreateWorkspaceView.
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            provider: ProviderInfo(id: "auggie", authenticated: true),
            model: makeModel("opus4.7")
        )
        #expect(selection.provider == nil)
        #expect(selection.model == "opus4.7")
    }

    @Test func sendsProviderAndModelForNonAuggieProvider() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            provider: ProviderInfo(id: "claude-code", authenticated: true),
            model: makeModel("sonnet-4.6", provider: "claude-code", isDefault: true)
        )
        #expect(selection.provider == "claude-code")
        #expect(selection.model == "sonnet-4.6")
    }

    @Test func sendsProviderOnlyWhenNoExplicitPick() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            provider: ProviderInfo(id: "grok", authenticated: nil),
            model: nil
        )
        #expect(selection.provider == "grok")
        #expect(selection.model == nil)
    }

    @Test func omitsBothWhenNoProviderSelected() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(provider: nil, model: nil)
        #expect(selection.provider == nil)
        #expect(selection.model == nil)
    }
}
