extension SpecialistPickerView {
    /// Providers with `authenticated == false` are not selectable;
    /// `nil` (unknown) stays selectable since probes can fail transiently.
    static func isSelectable(_ provider: ProviderInfo) -> Bool {
        provider.isSelectable
    }

    /// The Create action is unavailable while required selections are absent,
    /// loading is active, or no provider can be selected (monorepo#1003).
    static func isCreateDisabled(
        hasSpecialist: Bool,
        isCreating: Bool,
        isLoadingProviders: Bool,
        isLoadingModels: Bool,
        providers: [ProviderInfo]
    ) -> Bool {
        !hasSpecialist || isCreating || isLoadingProviders || isLoadingModels || providers.noneSelectable
    }

    /// Keeps the current selection when it is still selectable, otherwise falls
    /// back to auggie if selectable, else the first selectable provider.
    static func resolveProviderSelection(current: ProviderInfo?, providers: [ProviderInfo]) -> ProviderInfo? {
        let selectable = providers.filter { isSelectable($0) }
        if let current, let updated = selectable.first(where: { $0.id == current.id }) {
            return updated
        }
        return selectable.first { $0.id == "auggie" } ?? selectable.first
    }

    /// Distinguishes a superseded fetch from a current fetch whose provider
    /// changed, preserving whether an empty model catalog should be applied.
    static func modelFetchOutcome(
        fetched: [ModelInfo],
        requestedProviderId: String,
        selectedProviderId: String?,
        requestGeneration: Int,
        latestGeneration: Int
    ) -> SpecialistModelFetchOutcome {
        guard requestGeneration == latestGeneration else { return .superseded }
        guard selectedProviderId == requestedProviderId else { return .noModelUpdate }
        return .replaceModels(fetched)
    }

    /// Builds the provider/model params for `agent.create`; auggie is omitted
    /// because it is the daemon default, and model is sent only when selected.
    static func buildCreateAgentSelection(
        provider: ProviderInfo?,
        model: ModelInfo?
    ) -> (provider: String?, model: String?) {
        let providerId = provider?.id
        return (providerId == "auggie" ? nil : providerId, model?.id)
    }
}
