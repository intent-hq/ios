import Testing
@testable import Intent

/// Tests for the SpecialistPickerView step-2 selection helpers:
/// provider selection/fallback, default model resolution, and the
/// provider/model params sent on agent.create.
struct SpecialistPickerSelectionTests {
    private func makeSpecialist(tier: String? = "balanced", model: String? = nil) -> SpecialistInfo {
        SpecialistInfo(id: "implementor", name: "Implementor", description: "Implements tasks", modelTier: tier, model: model)
    }

    private func makeModel(_ id: String, provider: String = "auggie", isDefault: Bool = false) -> ModelInfo {
        ModelInfo(id: id, name: id, provider: provider, isDefault: isDefault)
    }

    // MARK: - resolveProviderSelection

    @Test func defaultsToAuggieWhenSelectable() {
        let providers = [
            ProviderInfo(id: "claude-code", authenticated: true),
            ProviderInfo(id: "auggie", authenticated: true),
        ]
        #expect(SpecialistPickerView.resolveProviderSelection(current: nil, providers: providers)?.id == "auggie")
    }

    @Test func unauthenticatedProvidersAreNotSelectable() {
        #expect(SpecialistPickerView.isSelectable(ProviderInfo(id: "auggie", authenticated: true)))
        #expect(SpecialistPickerView.isSelectable(ProviderInfo(id: "grok", authenticated: nil)))
        #expect(!SpecialistPickerView.isSelectable(ProviderInfo(id: "codex", authenticated: false)))
    }

    @Test func fallsBackToFirstSelectableWhenAuggieSignedOut() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "claude-code", authenticated: false),
            ProviderInfo(id: "grok", authenticated: nil),
        ]
        #expect(SpecialistPickerView.resolveProviderSelection(current: nil, providers: providers)?.id == "grok")
    }

    @Test func keepsCurrentSelectionWhenStillSelectable() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: true),
            ProviderInfo(id: "claude-code", authenticated: true),
        ]
        let current = ProviderInfo(id: "claude-code", authenticated: true)
        #expect(SpecialistPickerView.resolveProviderSelection(current: current, providers: providers)?.id == "claude-code")
    }

    @Test func fallsBackWhenCurrentSelectionBecomesDisabled() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: true),
            ProviderInfo(id: "claude-code", authenticated: false),
        ]
        let current = ProviderInfo(id: "claude-code", authenticated: true)
        #expect(SpecialistPickerView.resolveProviderSelection(current: current, providers: providers)?.id == "auggie")
    }

    @Test func returnsNilWhenNoProviderSelectable() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "codex", authenticated: false),
        ]
        #expect(SpecialistPickerView.resolveProviderSelection(current: nil, providers: providers) == nil)
        #expect(SpecialistPickerView.resolveProviderSelection(current: nil, providers: []) == nil)
    }

    // MARK: - defaultAuggieModelId

    @Test func defaultAuggieModelIdPrefersConfiguredModel() {
        #expect(SpecialistPickerView.defaultAuggieModelId(for: makeSpecialist(model: "opus4.6")) == "opus4.6")
    }

    @Test func defaultAuggieModelIdMapsTiers() {
        #expect(SpecialistPickerView.defaultAuggieModelId(for: makeSpecialist(tier: "fast")) == "haiku4.5")
        #expect(SpecialistPickerView.defaultAuggieModelId(for: makeSpecialist(tier: "smart")) == "opus4.6")
        #expect(SpecialistPickerView.defaultAuggieModelId(for: makeSpecialist(tier: "balanced")) == "sonnet4.5")
        #expect(SpecialistPickerView.defaultAuggieModelId(for: nil) == "sonnet4.5")
    }

    // MARK: - defaultModel

    @Test func auggieDefaultModelPrefersSpecialistDefault() {
        let models = [makeModel("sonnet4.5", isDefault: true), makeModel("opus4.6")]
        let picked = SpecialistPickerView.defaultModel(in: models, providerId: "auggie", specialist: makeSpecialist(model: "opus4.6"))
        #expect(picked?.id == "opus4.6")
    }

    @Test func nonAuggieDefaultModelUsesIsDefaultFlag() {
        let models = [makeModel("opus-4.5", provider: "claude-code"), makeModel("sonnet-4.6", provider: "claude-code", isDefault: true)]
        let picked = SpecialistPickerView.defaultModel(in: models, providerId: "claude-code", specialist: makeSpecialist(model: "opus4.6"))
        #expect(picked?.id == "sonnet-4.6")
    }

    @Test func defaultModelFallsBackToFirstAndNilWhenEmpty() {
        let models = [makeModel("grok-4", provider: "grok"), makeModel("grok-4-fast", provider: "grok")]
        #expect(SpecialistPickerView.defaultModel(in: models, providerId: "grok", specialist: nil)?.id == "grok-4")
        #expect(SpecialistPickerView.defaultModel(in: [], providerId: "grok", specialist: nil) == nil)
    }

    // MARK: - buildCreateAgentSelection

    @Test func omitsBothWhenAuggieModelMatchesConfiguredModel() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            specialist: makeSpecialist(model: "sonnet4.5"),
            provider: ProviderInfo(id: "auggie", authenticated: true),
            model: makeModel("sonnet4.5")
        )
        #expect(selection.provider == nil)
        #expect(selection.model == nil)
    }

    @Test func omitsBothWhenAuggieModelMatchesTierDefault() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            specialist: makeSpecialist(tier: "smart"),
            provider: ProviderInfo(id: "auggie", authenticated: true),
            model: makeModel("opus4.6")
        )
        #expect(selection.provider == nil)
        #expect(selection.model == nil)
    }

    @Test func omitsBothWhenNoProviderOrNoAuggieModel() {
        let noProvider = SpecialistPickerView.buildCreateAgentSelection(
            specialist: makeSpecialist(),
            provider: nil,
            model: makeModel("opus4.6")
        )
        #expect(noProvider.provider == nil)
        #expect(noProvider.model == nil)

        let noModel = SpecialistPickerView.buildCreateAgentSelection(
            specialist: makeSpecialist(),
            provider: ProviderInfo(id: "auggie", authenticated: true),
            model: nil
        )
        #expect(noModel.provider == nil)
        #expect(noModel.model == nil)
    }

    @Test func sendsProviderAndModelWhenAuggieModelOverridden() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            specialist: makeSpecialist(model: "sonnet4.5"),
            provider: ProviderInfo(id: "auggie", authenticated: true),
            model: makeModel("opus4.6")
        )
        #expect(selection.provider == "auggie")
        #expect(selection.model == "opus4.6")
    }

    @Test func sendsProviderAndModelForNonAuggieProvider() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            specialist: makeSpecialist(model: "sonnet4.5"),
            provider: ProviderInfo(id: "claude-code", authenticated: true),
            model: makeModel("sonnet-4.6", provider: "claude-code", isDefault: true)
        )
        #expect(selection.provider == "claude-code")
        #expect(selection.model == "sonnet-4.6")
    }

    @Test func sendsProviderOnlyWhenModelCatalogEmpty() {
        let selection = SpecialistPickerView.buildCreateAgentSelection(
            specialist: makeSpecialist(),
            provider: ProviderInfo(id: "grok", authenticated: nil),
            model: nil
        )
        #expect(selection.provider == "grok")
        #expect(selection.model == nil)
    }

    // MARK: - modelFetchOutcome (stale-response guard + loading reset)

    @Test func modelFetchOutcomeAppliesCurrentProviderResults() {
        let fetched = [makeModel("sonnet4.5", isDefault: true), makeModel("opus4.6")]
        let outcome = SpecialistPickerView.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: "auggie",
            selectedProviderId: "auggie",
            specialist: makeSpecialist(tier: "smart")
        )
        #expect(outcome.models?.map(\.id) == ["sonnet4.5", "opus4.6"])
        #expect(outcome.selectedModel?.id == "opus4.6")
        #expect(!outcome.isLoadingModels)
    }

    @Test func modelFetchOutcomeDropsStaleProviderResults() {
        let outcome = SpecialistPickerView.modelFetchOutcome(
            fetched: [makeModel("grok-4", provider: "grok")],
            requestedProviderId: "grok",
            selectedProviderId: "auggie",
            specialist: nil
        )
        #expect(outcome.models == nil)
        #expect(outcome.selectedModel == nil)
        #expect(!outcome.isLoadingModels)
    }

    @Test func modelFetchOutcomeClearsLoadingWhenProviderDeselected() {
        // Regression: a provider refresh can resolve the selection to nil while
        // a fetch is in flight; the loading flag must still clear so the
        // Create button doesn't wedge disabled.
        let outcome = SpecialistPickerView.modelFetchOutcome(
            fetched: [makeModel("sonnet4.5")],
            requestedProviderId: "auggie",
            selectedProviderId: nil,
            specialist: makeSpecialist()
        )
        #expect(outcome.models == nil)
        #expect(!outcome.isLoadingModels)
    }
}
