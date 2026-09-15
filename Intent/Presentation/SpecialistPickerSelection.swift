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

    /// Keeps the selection while `current`'s id is still pickable in the
    /// unfiltered `catalog`, rebound to the fresh entry so refreshed
    /// metadata is what the picker shows; otherwise the resolved
    /// orchestrator (PROTOCOL §5.11), else the first pickable specialist in
    /// daemon order, else nil when the catalog lists nothing pickable (a
    /// hidden id must never be submitted). An empty catalog (cold load or
    /// reconnect clear) keeps `current` so the selection survives the reload.
    static func reconciledSpecialist(
        current: SpecialistInfo?, catalog: [SpecialistInfo]
    ) -> SpecialistInfo? {
        guard !catalog.isEmpty else { return current }
        let pickable = catalog.modalPickable
        if let current, let fresh = pickable.first(where: { $0.id == current.id }) {
            return fresh
        }
        return pickable.orchestrator ?? pickable.first
    }

    /// The Model section's loading state: shown while the selected
    /// provider's catalog is not cached and this sheet's load for it has not
    /// settled; never for a cached catalog (revalidation is silent), and not
    /// after a settled load that failed (the daemon-default row instead).
    static func showsModelsLoading(catalog: [ModelInfo]?, settled: Bool) -> Bool {
        catalog == nil && !settled
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