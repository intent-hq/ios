import Foundation

enum CreationSelectionPolicy {
    static func preselectedWorkspaceProvider(
        current: ProviderInfo?, providers: [ProviderInfo]
    ) -> ProviderInfo? {
        guard !providers.isEmpty else { return nil }
        return preselectedProvider(current: current, providers: providers)
    }

    static func reconcileWorkspaceProvider(
        provider: inout ProviderInfo?, model: inout ModelInfo?, state: WorkspaceProviderOptions.State
    ) {
        let providers: [ProviderInfo]
        switch state {
        case .idle, .loading:
            return
        case .failed:
            providers = []
        case let .loaded(loadedProviders):
            providers = loadedProviders
        }
        let previousId = provider?.id
        provider = preselectedWorkspaceProvider(current: provider, providers: providers)
        if provider == nil || provider?.id != previousId { model = nil }
    }

    static func workspacePickerSpecialists(_ specialists: [SpecialistInfo]) -> [SpecialistInfo] {
        let pickable = specialists.modalPickable
        let orchestratorId = pickable.orchestrator?.id
        return pickable.sorted { firstSpecialist, secondSpecialist in
            let firstIsOrchestrator = firstSpecialist.id == orchestratorId
            let secondIsOrchestrator = secondSpecialist.id == orchestratorId
            if firstIsOrchestrator != secondIsOrchestrator { return firstIsOrchestrator }
            return firstSpecialist.name < secondSpecialist.name
        }
    }

    static func preselectedWorkspaceSpecialist(
        current: SpecialistInfo?, catalog: [SpecialistInfo]
    ) -> SpecialistInfo? {
        guard !catalog.isEmpty else { return current }
        let specialists = workspacePickerSpecialists(catalog)
        if let current, let fresh = specialists.first(where: { $0.id == current.id }) {
            return fresh
        }
        return specialists.orchestrator ?? specialists.first
    }

    static func preselectedProvider(
        current: ProviderInfo?, providers: [ProviderInfo]
    ) -> ProviderInfo? {
        guard !providers.isEmpty else { return current }
        let selectable = providers.filter(\.isSelectable)
        if let current, let fresh = selectable.first(where: { $0.id == current.id }) {
            return fresh
        }
        return selectable.first { $0.id == "auggie" } ?? selectable.first
    }

    static func reconciledModel(current: ModelInfo?, models: [ModelInfo]) -> ModelInfo? {
        guard let current else { return nil }
        return models.first { $0.id == current.id && $0.provider == current.provider }
    }

    static func workspaceReasoningLevels(
        provider: ProviderInfo?, model: ModelInfo?, models: [ModelInfo]
    ) -> [String] {
        guard let provider, provider.isSelectable, model?.provider == provider.id,
              let fresh = reconciledModel(current: model, models: models) else { return [] }
        var seen = Set<String>()
        return fresh.effortLevels.filter { level in
            !level.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(level).inserted
        }
    }

    static func reconciledReasoningEffort(current: String?, effortLevels: [String]) -> String? {
        guard let current, effortLevels.contains(current) else { return nil }
        return current
    }
}
