@testable import Intent
import Testing

/// Tests for the SpecialistPickerView step-2 selection helpers:
/// provider selection/fallback, default model resolution, and the
/// provider/model params sent on agent.create.
struct SpecialistPickerSelectionTests {
    private func makeSpecialist(resolvedModel: String? = nil, resolvedProvider: String? = nil) -> SpecialistInfo {
        SpecialistInfo(
            id: "implementor",
            name: "Implementor",
            description: "Implements tasks",
            resolvedModel: resolvedModel,
            resolvedProvider: resolvedProvider
        )
    }

    private func makeModel(_ id: String, provider: String = "auggie", isDefault: Bool = false) -> ModelInfo {
        ModelInfo(id: id, name: id, provider: provider, isDefault: isDefault)
    }

    // MARK: - resolveProviderSelection

    @Test func defaultsToAuggieWhenSelectable() {
        let providers = [
            ProviderInfo(id: "claude-code", authenticated: true),
            ProviderInfo(id: "auggie", authenticated: true)
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
            ProviderInfo(id: "grok", authenticated: nil)
        ]
        #expect(SpecialistPickerView.resolveProviderSelection(current: nil, providers: providers)?.id == "grok")
    }

    @Test func keepsCurrentSelectionWhenStillSelectable() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: true),
            ProviderInfo(id: "claude-code", authenticated: true)
        ]
        let current = ProviderInfo(id: "claude-code", authenticated: true)
        #expect(SpecialistPickerView.resolveProviderSelection(current: current, providers: providers)?.id == "claude-code")
    }

    @Test func fallsBackWhenCurrentSelectionBecomesDisabled() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: true),
            ProviderInfo(id: "claude-code", authenticated: false)
        ]
        let current = ProviderInfo(id: "claude-code", authenticated: true)
        #expect(SpecialistPickerView.resolveProviderSelection(current: current, providers: providers)?.id == "auggie")
    }

    @Test func returnsNilWhenNoProviderSelectable() {
        let providers = [
            ProviderInfo(id: "auggie", authenticated: false),
            ProviderInfo(id: "codex", authenticated: false)
        ]
        #expect(SpecialistPickerView.resolveProviderSelection(current: nil, providers: providers) == nil)
        #expect(SpecialistPickerView.resolveProviderSelection(current: nil, providers: []) == nil)
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
            ProviderInfo(id: "grok", authenticated: nil)
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
            ProviderInfo(id: "codex", authenticated: false)
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

    // MARK: - modelFetchOutcome (stale-response guard + loading reset)

    @Test func modelFetchOutcomeAppliesCurrentProviderResults() throws {
        // A fresh catalog resets the selection to the daemon-default row (nil).
        let fetched = [makeModel("sonnet4.5", isDefault: true), makeModel("opus4.7")]
        let outcome = try #require(SpecialistPickerView.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: "auggie",
            selectedProviderId: "auggie",
            requestGeneration: 1,
            latestGeneration: 1
        ))
        #expect(outcome.models?.map(\.id) == ["sonnet4.5", "opus4.7"])
        #expect(outcome.selectedModel == nil)
        #expect(!outcome.isLoadingModels)
    }

    @Test func modelFetchOutcomeIgnoresSupersededFetchEntirely() {
        // Regression: a late response from an older fetch must be ignored
        // entirely while a newer fetch is still in flight — it must not
        // clear isLoadingModels (or the previous provider's catalog could
        // briefly present as the current provider's and allow a mismatched
        // (provider, model) pair on create).
        let outcome = SpecialistPickerView.modelFetchOutcome(
            fetched: [makeModel("grok-4", provider: "grok")],
            requestedProviderId: "grok",
            selectedProviderId: "grok",
            requestGeneration: 1,
            latestGeneration: 2
        )
        #expect(outcome == nil)
    }

    @Test func modelFetchOutcomeDropsStaleProviderResults() throws {
        let outcome = try #require(SpecialistPickerView.modelFetchOutcome(
            fetched: [makeModel("grok-4", provider: "grok")],
            requestedProviderId: "grok",
            selectedProviderId: "auggie",
            requestGeneration: 2,
            latestGeneration: 2
        ))
        #expect(outcome.models == nil)
        #expect(outcome.selectedModel == nil)
        #expect(!outcome.isLoadingModels)
    }

    @Test func modelFetchOutcomeClearsLoadingWhenProviderDeselected() throws {
        // Regression: a provider refresh can resolve the selection to nil while
        // a fetch is in flight; the loading flag must still clear so the
        // Create button doesn't wedge disabled.
        let outcome = try #require(SpecialistPickerView.modelFetchOutcome(
            fetched: [makeModel("sonnet4.5")],
            requestedProviderId: "auggie",
            selectedProviderId: nil,
            requestGeneration: 1,
            latestGeneration: 1
        ))
        #expect(outcome.models == nil)
        #expect(!outcome.isLoadingModels)
    }
}
