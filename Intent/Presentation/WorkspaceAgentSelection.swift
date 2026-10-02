import Foundation
import Observation

struct WorkspaceAgentPreferences: Codable, Equatable {
    enum SpecialistMode: String, Codable {
        case automatic
        case noSpecialist = "none"
        case selected
    }

    var specialistID: String?
    var providerID: String?
    var modelID: String?
    var reasoningEffort: String?
    var specialistMode: SpecialistMode?
}

extension PersistenceManager {
    func loadWorkspaceAgentPreferences(for backendID: BackendID?) -> WorkspaceAgentPreferences? {
        guard let backendID,
              let data = defaults.data(forKey: "workspaceAgentPreferences.\(backendID.connectionID.uuidString)") else { return nil }
        return try? JSONDecoder().decode(WorkspaceAgentPreferences.self, from: data)
    }

    func saveWorkspaceAgentPreferences(_ preferences: WorkspaceAgentPreferences, for backendID: BackendID?) {
        guard let backendID, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: "workspaceAgentPreferences.\(backendID.connectionID.uuidString)")
    }
}

@MainActor
@Observable
final class WorkspaceAgentSelection {
    private(set) var specialist: SpecialistInfo?
    private(set) var provider: ProviderInfo?
    private(set) var model: ModelInfo?
    private(set) var reasoningEffort: String?
    private var preferences: WorkspaceAgentPreferences?
    private let persistence: PersistenceManager
    private let backendID: BackendID?

    init(backendID: BackendID?, persistence: PersistenceManager) {
        self.backendID = backendID
        self.persistence = persistence
        preferences = persistence.loadWorkspaceAgentPreferences(for: backendID)
    }

    func reconcileSpecialist(catalog: [SpecialistInfo]) {
        guard !catalog.isEmpty else { return }
        if preferences?.specialistMode == .noSpecialist {
            specialist = nil
            return
        }
        let remembered = catalog.modalPickable.first { $0.id == preferences?.specialistID }
        specialist = CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: remembered ?? specialist, catalog: catalog)
    }

    func reconcileProvider(state: WorkspaceProviderOptions.State) {
        let previousID = provider?.id
        if case let .loaded(providers) = state,
           let remembered = providers.first(where: { $0.id == preferences?.providerID && $0.isSelectable }) {
            provider = remembered
        }
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: state)
        if provider == nil || provider?.id != previousID {
            model = nil
            reasoningEffort = nil
        }
    }

    func reconcileModels(_ models: [ModelInfo]) {
        if let preferences {
            model = models.first { candidate in
                candidate.id == preferences.modelID && candidate.provider == preferences.providerID && candidate.provider == provider?.id
            }
        } else {
            model = CreationSelectionPolicy.reconciledModel(current: model, models: models)
        }
        let levels = CreationSelectionPolicy.workspaceReasoningLevels(provider: provider, model: model, models: models)
        reasoningEffort = CreationSelectionPolicy.reconciledReasoningEffort(current: preferences?.reasoningEffort, effortLevels: levels)
    }

    func reconcileReasoning(effortLevels: [String]) {
        reasoningEffort = CreationSelectionPolicy.reconciledReasoningEffort(current: reasoningEffort, effortLevels: effortLevels)
    }

    func selectSpecialist(_ specialist: SpecialistInfo?) {
        self.specialist = specialist
        remember { next in
            next.specialistID = specialist?.id
            next.specialistMode = specialist == nil ? .noSpecialist : .selected
        }
    }

    func selectProvider(_ provider: ProviderInfo) {
        guard provider.isSelectable, provider.id != self.provider?.id else { return }
        self.provider = provider
        model = nil
        reasoningEffort = nil
        remember { next in
            next.providerID = provider.id
            next.modelID = nil
            next.reasoningEffort = nil
        }
    }

    func selectModel(_ model: ModelInfo?) {
        self.model = model?.provider == provider?.id ? model : nil
        reconcileReasoning(effortLevels: self.model?.effortLevels ?? [])
        remember { next in
            next.providerID = provider?.id
            next.modelID = self.model?.id
            next.reasoningEffort = reasoningEffort
        }
    }

    func selectReasoning(_ effort: String?) {
        reasoningEffort = CreationSelectionPolicy.reconciledReasoningEffort(current: effort, effortLevels: model?.effortLevels ?? [])
        remember { $0.reasoningEffort = reasoningEffort }
    }

    private func remember(_ update: (inout WorkspaceAgentPreferences) -> Void) {
        var next = preferences ?? WorkspaceAgentPreferences(
            specialistID: specialist?.id, providerID: provider?.id, modelID: model?.id, reasoningEffort: reasoningEffort,
            specialistMode: specialist == nil ? .automatic : .selected
        )
        update(&next)
        preferences = next
        persistence.saveWorkspaceAgentPreferences(next, for: backendID)
    }
}
