extension SpecialistPickerView {
    /// Providers with `authenticated == false` are not selectable;
    /// `nil` (unknown) stays selectable since probes can fail transiently.
    static func isSelectable(_ provider: ProviderInfo) -> Bool {
        provider.isSelectable
    }

    static func selectableModels(
        provider: ProviderInfo?, providers: [ProviderInfo], models: [ModelInfo]
    ) -> [ModelInfo] {
        guard let provider,
              providers.contains(where: { $0.id == provider.id && $0.isSelectable }) else { return [] }
        return models.filter { $0.provider == provider.id }
    }

    /// The Create action is unavailable while required selections are absent,
    /// loading is active, or no provider can be selected (monorepo#1003).
    static func isCreateDisabled(
        hasSpecialist: Bool,
        isCreating: Bool,
        isLoadingOptions: Bool,
        providers: [ProviderInfo],
        selectedProvider: ProviderInfo?
    ) -> Bool {
        guard let selectedProvider,
              providers.contains(where: { $0.id == selectedProvider.id && $0.isSelectable }) else { return true }
        return !hasSpecialist || isCreating || isLoadingOptions
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

    // The Model section's loading state distinguishes no catalog from an empty
    // settled catalog, so the optional collection is intentional.
    // `nil` means no catalog has arrived; an empty catalog is a settled result.
    // swiftlint:disable:next discouraged_optional_collection
    static func showsModelsLoading(catalog: [ModelInfo]?, settled: Bool) -> Bool {
        catalog == nil && !settled
    }

    /// This sheet's settled-load markers, gated by the store's
    /// `loadGeneration`: a marker is published only when the load returned
    /// in the generation it started in. A load superseded by a reconnect
    /// clear (`invalidate()`) returns for a cache the store already dropped;
    /// settling on it would show the daemon-default row and enable Create
    /// while the fresh load for the same provider is still pending.
    struct SettledLoads {
        private(set) var options = false
        private(set) var modelProviders: Set<String> = []

        /// Returns true when the marker was published (the load is current).
        @discardableResult
        mutating func settleOptions(startedAt: Int, current: Int) -> Bool {
            guard startedAt == current else { return false }
            options = true
            return true
        }

        @discardableResult
        mutating func settleModels(for providerId: String, startedAt: Int, current: Int) -> Bool {
            guard startedAt == current else { return false }
            modelProviders.insert(providerId)
            return true
        }

        /// A reconnect clear: every marker belonged to the dropped cache.
        mutating func reset() {
            self = Self()
        }
    }

    /// Builds the provider/model params for `agent.create`; auggie is omitted
    /// because it is the daemon default, and model is sent only when selected.
    static func buildCreateAgentSelection(
        provider: ProviderInfo?,
        model: ModelInfo?
    ) -> (provider: String?, model: String?) {
        guard let provider, provider.isSelectable else { return (nil, nil) }
        let providerId = provider.id
        return (providerId == "auggie" ? nil : providerId, model?.provider == providerId ? model?.id : nil)
    }
}
