extension SpecialistPickerView {
    static func selectableModels(
        provider: ProviderInfo?, providers: [ProviderInfo], models: [ModelInfo]
    ) -> [ModelInfo] {
        guard let provider,
              providers.contains(where: { $0.id == provider.id && $0.isSelectable }) else { return [] }
        return models.filter { $0.provider == provider.id }
    }

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

    // swiftlint:disable:next discouraged_optional_collection
    static func showsModelsLoading(catalog: [ModelInfo]?, settled: Bool) -> Bool {
        catalog == nil && !settled
    }

    struct SettledLoads {
        private(set) var options = false
        private(set) var modelProviders: Set<String> = []

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

        mutating func reset() {
            self = Self()
        }
    }

    static func buildCreateAgentSelection(
        provider: ProviderInfo?,
        model: ModelInfo?
    ) -> (provider: String?, model: String?) {
        guard let provider, provider.isSelectable else { return (nil, nil) }
        let providerId = provider.id
        return (providerId == "auggie" ? nil : providerId, model?.provider == providerId ? model?.id : nil)
    }
}
