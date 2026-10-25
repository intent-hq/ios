import Foundation
import Observation

@MainActor
@Observable final class ConversationModelSelection {
    private(set) var providerID: String?
    private(set) var modelID: String?
    var reasoningEffort: String?
    private(set) var isLoading = true
    private(set) var isLoadingModels = false
    private(set) var isSaving = false
    var errorMessage: String?
    private var initialized = false
    private var isActive = true
    private let consumer = UUID()
    let viewModel: ConversationViewModel

    init(viewModel: ConversationViewModel) { self.viewModel = viewModel }

    var options: CreationOptionsStore { viewModel.optionsStore }
    var providerOptions: WorkspaceProviderOptions { options.workspaceProviderOptions }
    var providers: [ProviderInfo] {
        guard case .loaded = providerOptions.state else { return [] }
        var providers = providerOptions.providers
        if let current = viewModel.modelProviderId {
            providers.removeAll { $0.id == current }
            providers.append(ProviderInfo(id: current))
        }
        return providers
    }
    var provider: ProviderInfo? { providers.first { $0.id == providerID } }
    var providerGuidance: String? { providers.isEmpty ? providerOptions.guidance : nil }
    var models: [ModelInfo] { providerID.flatMap { options.models(for: $0) } ?? [] }
    var model: ModelInfo? {
        guard let modelID, let providerID else { return nil }
        return models.first { $0.id == modelID } ?? ModelInfo(id: modelID, name: modelID, provider: providerID)
    }
    var reasoningLevels: [String] {
        CreationSelectionPolicy.workspaceReasoningLevels(provider: provider, model: model, models: models)
    }
    var modelGuidance: String? {
        guard let providerID, !isLoadingModels else { return nil }
        if options.modelCatalog(for: providerID).loadFailed { return "The model list could not be loaded. You can retry or use Provider default." }
        return models.isEmpty ? "No models are listed. You can use Provider default or retry." : nil
    }
    var catalogKey: ConversationViewModel.ModelCatalogKey {
        .init(providerId: providerID, isCached: false, loadGeneration: options.loadGeneration)
    }
    var canSave: Bool {
        guard isActive, !isLoading, !isLoadingModels, !isSaving, provider?.isSelectable == true else { return false }
        guard let providerID, options.models(for: providerID) != nil || options.modelCatalog(for: providerID).loadFailed else { return false }
        return providerID != viewModel.modelProviderId || (modelID ?? "default") != (viewModel.currentModelId ?? "default")
            || reasoningEffort != viewModel.currentReasoningEffort
    }

    func load() async {
        isLoading = true
        let generation = options.loadGeneration
        async let providers: () = providerOptions.load()
        await viewModel.loadModelCatalogIfNeeded()
        await providers
        guard isActive, !Task.isCancelled, generation == options.loadGeneration else { return }
        if !initialized {
            modelID = viewModel.currentModelId == "default" ? nil : viewModel.currentModelId
            reasoningEffort = viewModel.currentReasoningEffort
            providerID = viewModel.modelProviderId
            initialized = true
        }
        isLoading = false
    }

    func selectProvider(_ provider: ProviderInfo) {
        guard provider.isSelectable, provider.id != providerID else { return }
        modelID = nil
        reasoningEffort = nil
        providerID = provider.id
    }

    func selectModel(_ model: ModelInfo?) {
        modelID = model?.id
        reasoningEffort = CreationSelectionPolicy.reconciledReasoningEffort(current: reasoningEffort, effortLevels: reasoningLevels)
    }

    func loadModels() async {
        guard let providerID, isActive, !Task.isCancelled else { return }
        let generation = options.loadGeneration
        isLoadingModels = true
        options.selectModelProvider(providerID, consumer: consumer)
        await options.loadModelsIfNeeded(providerId: providerID, force: true, consumer: consumer)
        guard isActive, !Task.isCancelled, generation == options.loadGeneration, providerID == self.providerID else { return }
        isLoadingModels = false
    }

    func save() async -> Bool {
        guard canSave, let providerID else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await viewModel.saveModelSelection(providerID: providerID, modelID: modelID ?? "default", reasoningEffort: reasoningEffort)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deactivate() {
        isActive = false
        options.releaseCatalogs(consumer: consumer)
    }

    isolated deinit { options.releaseCatalogs(consumer: consumer) }
}
