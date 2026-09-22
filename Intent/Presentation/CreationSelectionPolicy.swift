/// Stateless selection rules shared by the workspace and agent creation flows.
enum CreationSelectionPolicy {
    /// Workspace enablement is authoritative even when empty or unavailable;
    /// never retain a provider that is no longer offered by this host.
    static func preselectedWorkspaceProvider(
        current: ProviderInfo?, providers: [ProviderInfo]
    ) -> ProviderInfo? {
        guard !providers.isEmpty else { return nil }
        return preselectedProvider(current: current, providers: providers)
    }

    static func reconcileWorkspaceProvider(
        provider: inout ProviderInfo?, model: inout ModelInfo?, providers: [ProviderInfo]
    ) {
        let previousId = provider?.id
        provider = preselectedWorkspaceProvider(current: provider, providers: providers)
        if provider == nil || provider?.id != previousId { model = nil }
    }

    /// The workspace picker's specialist list: the modal-pickable set (no
    /// hidden or internal specialists) with the orchestrator pinned first,
    /// then by name.
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

    /// Keeps the workspace selection while `current`'s id is still pickable
    /// in the unfiltered `catalog`, rebound to the fresh entry so refreshed
    /// metadata (default-model preview) is what the picker shows; otherwise
    /// the orchestrator, else the first pickable specialist, else nil when
    /// the catalog lists nothing pickable (a hidden id must never be
    /// submitted). An empty catalog (cold load or reconnect clear) keeps
    /// `current` so the selection survives the reload.
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

    /// Keeps the selection while `current`'s id is still selectable, rebound
    /// to the fresh entry; otherwise auggie when selectable, else the first
    /// selectable provider, else nil (nothing selectable — the picker shows
    /// setup guidance). An empty list keeps `current` so the selection
    /// survives a reconnect reload.
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

    /// Keeps an explicit model only while the displayed catalog still lists
    /// it for the same provider (rebound to the fresh entry); anything else
    /// — the model retired, the catalog cleared, or a provider switch whose
    /// catalog reuses the bare id — falls back to the daemon default (nil).
    static func reconciledModel(current: ModelInfo?, models: [ModelInfo]) -> ModelInfo? {
        guard let current else { return nil }
        return models.first { $0.id == current.id && $0.provider == current.provider }
    }
}
