import Foundation
@testable import Intent
import Testing

/// Tests for the SpecialistPickerView selection helpers: specialist
/// reconciliation against the cached catalog, the loading states derived
/// from `CreationOptionsStore` (cached and cold paths), and the
/// provider/model params sent on agent.create. Shared provider defaulting and
/// model reconciliation use `CreationSelectionPolicy` (covered in this suite's
/// loading tests and `CreateWorkspaceParamsTests`).
struct SpecialistPickerSelectionTests {
    func makeSpecialist(resolvedModel: String? = nil, resolvedProvider: String? = nil) -> SpecialistInfo {
        SpecialistInfo(
            id: "implementor",
            name: "Implementor",
            description: "Implements tasks",
            resolvedModel: resolvedModel,
            resolvedProvider: resolvedProvider
        )
    }

    func makeCatalogSpecialist(
        id: String,
        name: String,
        hidden: Bool = false,
        role: String? = nil
    ) -> SpecialistInfo {
        SpecialistInfo(id: id, name: name, description: "", hidden: hidden, role: role)
    }

    func makeModel(_ id: String, provider: String = "auggie", isDefault: Bool = false) -> ModelInfo {
        ModelInfo(id: id, name: id, provider: provider, isDefault: isDefault)
    }

    // MARK: - isSelectable

    @Test func unauthenticatedProvidersAreNotSelectable() {
        #expect(SpecialistPickerView.isSelectable(ProviderInfo(id: "auggie", authenticated: true)))
        #expect(SpecialistPickerView.isSelectable(ProviderInfo(id: "grok", authenticated: .unknown)))
        #expect(!SpecialistPickerView.isSelectable(ProviderInfo(id: "codex", authenticated: false)))
    }

    // MARK: - reconciledSpecialist (cached catalog → New Agent selection)

    @Test func reconciledSpecialistDefaultsToOrchestratorElseFirstInDaemonOrder() {
        let withOrchestrator = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier"),
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator")
        ]
        #expect(
            SpecialistPickerView.reconciledSpecialist(
                current: nil,
                catalog: withOrchestrator
            )?.id == "coordinator"
        )
        // No orchestrator: the first pickable specialist as the daemon lists
        // it, not by name (the picker shows daemon order).
        let plain = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor")
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(current: nil, catalog: plain)?.id == "verifier")
    }

    @Test func reconciledSpecialistSkipsHiddenAndInternalDefaults() {
        let catalog = [
            makeCatalogSpecialist(id: "secret", name: "Secret", hidden: true),
            makeCatalogSpecialist(id: "helper", name: "Helper", role: "internal"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor")
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(current: nil, catalog: catalog)?.id == "implementor")
    }

    @Test func reconciledSpecialistRebindsSurvivingSelectionToFreshMetadata() {
        let current = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        var fresh = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        fresh.resolvedModel = "sonnet4.5"
        let catalog = [
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator"),
            fresh
        ]
        let reconciled = SpecialistPickerView.reconciledSpecialist(current: current, catalog: catalog)
        #expect(reconciled?.id == "implementor")
        #expect(reconciled?.resolvedModel == "sonnet4.5")
    }

    @Test func reconciledSpecialistRedefaultsWhenSelectionGoneOrHidden() {
        let current = makeCatalogSpecialist(id: "verifier", name: "Verifier")
        let gone = [
            makeCatalogSpecialist(id: "implementor", name: "Implementor"),
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator")
        ]
        #expect(SpecialistPickerView.reconciledSpecialist(current: current, catalog: gone)?.id == "coordinator")
        // Same ids, but the selection turned hidden under a refresh: a
        // hidden id must never be submitted.
        let hidden = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier", hidden: true),
            makeCatalogSpecialist(id: "implementor", name: "Implementor")
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
        let staleOptions = settled.settleOptions(startedAt: 0, current: 1)
        let staleModels = settled.settleModels(for: "auggie", startedAt: 0, current: 1)
        #expect(!staleOptions)
        #expect(!staleModels)
        #expect(!settled.options)
        #expect(settled.modelProviders.isEmpty)

        let currentOptions = settled.settleOptions(startedAt: 1, current: 1)
        let currentModels = settled.settleModels(for: "auggie", startedAt: 1, current: 1)
        #expect(currentOptions)
        #expect(currentModels)
        #expect(settled.options)
        #expect(settled.modelProviders == ["auggie"])

        settled.reset()
        #expect(!settled.options)
        #expect(settled.modelProviders.isEmpty)
    }

    // MARK: - noneSelectable (desktop-setup guidance state, monorepo#985)

    @Test func noneSelectableWhenAllProvidersSignedOut() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "codex", authenticated: false)
        ]
        #expect(providers.noneSelectable)
    }

    @Test func notNoneSelectableWhenEmpty() {
        #expect(![ProviderInfo]().noneSelectable)
    }

    @Test func notNoneSelectableWhenAnyProviderSelectable() {
        let signedIn = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "claude-code", authenticated: true)
        ]
        #expect(!signedIn.noneSelectable)

        // nil (unknown) stays selectable since probes can fail transiently
        let unknown = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "grok", authenticated: .unknown)
        ]
        #expect(!unknown.noneSelectable)
    }

    // MARK: - isCreateDisabled (Create unavailable in the guidance state, monorepo#1003)

    private func isCreateDisabled(
        providers: [ProviderInfo],
        hasSpecialist: Bool = true,
        isCreating: Bool = false,
        isLoadingProviders: Bool = false,
        isLoadingModels: Bool = false
    ) -> Bool {
        SpecialistPickerView.isCreateDisabled(
            hasSpecialist: hasSpecialist,
            isCreating: isCreating,
            isLoadingOptions: isLoadingProviders || isLoadingModels,
            providers: providers,
            selectedProvider: providers.first(where: \.isSelectable)
        )
    }

    @Test func createDisabledWhenNoProviderSelectable() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "codex", authenticated: false)
        ]
        #expect(isCreateDisabled(providers: providers))
    }

    @Test func createEnabledWhenAProviderIsSelectable() {
        #expect(!isCreateDisabled(providers: [ProviderInfo(id: "auggie", authenticated: true)]))
        // nil (unknown) stays selectable since probes can fail transiently
        #expect(!isCreateDisabled(providers: [ProviderInfo(id: "grok", authenticated: .unknown)]))
    }

    @Test func createDisabledWhenProviderListEmpty() {
        #expect(isCreateDisabled(providers: []))
    }

    @Test func createDisabledForMissingRemovedOrSignedOutSelection() {
        let providers = [ProviderInfo(id: "codex", authenticated: true), ProviderInfo(id: "auggie", authenticated: false)]
        for selection in [nil, ProviderInfo(id: "removed"), ProviderInfo(id: "auggie", authenticated: true)] {
            #expect(SpecialistPickerView.isCreateDisabled(
                hasSpecialist: true,
                isCreating: false,
                isLoadingOptions: false,
                providers: providers,
                selectedProvider: selection
            ))
        }
    }

    @Test func createDisabledWhileLoadingCreatingOrWithoutSpecialist() {
        let providers = [ProviderInfo(id: "auggie", authenticated: true)]
        #expect(isCreateDisabled(providers: providers, hasSpecialist: false))
        #expect(isCreateDisabled(providers: providers, isCreating: true))
        #expect(isCreateDisabled(providers: providers, isLoadingProviders: true))
        #expect(isCreateDisabled(providers: providers, isLoadingModels: true))
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
            provider: ProviderInfo(id: "grok", authenticated: .unknown),
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

    @Test func omitsStaleModelAfterProviderChanges() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            provider: ProviderInfo(id: "codex", authenticated: true),
            model: makeModel("shared-id", provider: "auggie")
        )
        #expect(selection.provider == "codex")
        #expect(selection.model == nil)
    }

    @Test func omitsModelWithoutSelectableProvider() {
        for provider in [nil, ProviderInfo(id: "auggie", authenticated: false)] {
            let selection = SpecialistPickerView.buildCreateAgentSelection(provider: provider, model: makeModel("opus4.7"))
            #expect(selection.provider == nil)
            #expect(selection.model == nil)
        }
    }
}

extension SpecialistPickerSelectionTests {
    @Test func modelsAreScopedToTheSelectedAvailableProvider() {
        let provider = ProviderInfo(id: "codex", authenticated: true)
        let model = makeModel("shared-id", provider: "codex")
        let catalog = [makeModel("shared-id"), model, makeModel("other", provider: "hidden")]
        #expect(SpecialistPickerView.selectableModels(provider: provider, providers: [provider], models: catalog) == [model])
        for providers in [[], [ProviderInfo(id: "auggie")], [ProviderInfo(id: "codex", authenticated: false)]] {
            #expect(SpecialistPickerView.selectableModels(provider: provider, providers: providers, models: catalog).isEmpty)
        }
        #expect(SpecialistPickerView.selectableModels(provider: nil, providers: [provider], models: catalog).isEmpty)
    }

    @Test func workspaceReasoningRequiresExplicitModelAndCurrentProviderEvidence() {
        let provider = ProviderInfo(id: "provider-a")
        let selected = ModelInfo(id: "shared-id", name: "Model", provider: provider.id, effortLevels: ["old"])
        let refreshed = ModelInfo(
            id: selected.id,
            name: "Model",
            provider: provider.id,
            effortLevels: ["future-level", "", "  \n", "future-level", "high"]
        )
        let levels = CreationSelectionPolicy.workspaceReasoningLevels(
            provider: provider, model: selected, models: [refreshed]
        )
        #expect(levels == ["future-level", "high"])
        #expect(CreationSelectionPolicy.reconciledReasoningEffort(current: "old", effortLevels: levels) == nil)
        #expect(CreationSelectionPolicy.reconciledReasoningEffort(current: "future-level", effortLevels: levels) == "future-level")
        #expect(CreationSelectionPolicy.reconciledReasoningEffort(current: nil, effortLevels: levels) == nil)

        // An unresolved default never borrows capabilities from the first or default row.
        #expect(CreationSelectionPolicy.workspaceReasoningLevels(provider: provider, model: nil, models: [refreshed]).isEmpty)
        let otherProviderModel = ModelInfo(
            id: selected.id, name: "Model", provider: "provider-b", effortLevels: ["future-level"]
        )
        #expect(CreationSelectionPolicy.workspaceReasoningLevels(
            provider: ProviderInfo(id: "provider-b"), model: selected, models: [otherProviderModel]
        ).isEmpty)
    }

    @Test func workspaceReasoningReturnsToAutoWhenModelCapabilityDisappears() {
        let provider = ProviderInfo(id: "provider-a")
        let selected = ModelInfo(id: "model", name: "Model", provider: provider.id, effortLevels: ["high"])
        let noMetadata = ModelInfo(id: selected.id, name: "Model", provider: provider.id)
        let changedModel = ModelInfo(id: "other", name: "Other", provider: provider.id, effortLevels: ["low"])
        for catalog in [[], [noMetadata], [changedModel]] {
            let levels = CreationSelectionPolicy.workspaceReasoningLevels(provider: provider, model: selected, models: catalog)
            #expect(CreationSelectionPolicy.reconciledReasoningEffort(current: "high", effortLevels: levels) == nil)
        }
        let signedOut = ProviderInfo(id: provider.id, authenticated: .signedOut)
        #expect(CreationSelectionPolicy.workspaceReasoningLevels(provider: signedOut, model: selected, models: [selected]).isEmpty)
        #expect(CreationSelectionPolicy.workspaceReasoningLevels(provider: nil, model: selected, models: [selected]).isEmpty)
    }
}
