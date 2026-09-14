import SwiftUI

struct SpecialistPickerView: View {
    private enum Route: Hashable {
        case provider
    }

    let workspaceId: String
    var agentStore: AgentStore
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var navigationPath: [Route] = []

    @State private var specialists: [SpecialistInfo] = []
    @State private var isLoadingSpecialists = true
    @State private var selectedSpecialist: SpecialistInfo?
    @State private var agentName: String = ""
    @State private var userEditedName: Bool = false
    @State private var isSettingNameFromSpecialist: Bool = false

    @State private var providers: [ProviderInfo] = []
    @State private var isLoadingProviders = true
    @State private var selectedProvider: ProviderInfo?
    @State private var models: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var modelFetchGeneration = 0
    @State private var selectedModel: ModelInfo?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SpecialistStepView(
                specialists: specialists,
                isLoadingSpecialists: isLoadingSpecialists,
                selectedSpecialist: selectedSpecialist,
                agentName: $agentName,
                colorScheme: colorScheme,
                onSelect: selectSpecialist,
                onDismiss: { dismiss() },
                onNext: { navigationPath.append(.provider) }
            )
            .task { await fetchSpecialists() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .provider:
                        ProviderModelStepView(
                            providers: providers,
                            isLoadingProviders: isLoadingProviders,
                            selectedProvider: $selectedProvider,
                            models: models,
                            isLoadingModels: isLoadingModels,
                            selectedModel: $selectedModel,
                            selectedSpecialist: selectedSpecialist,
                            isCreating: isCreating,
                            isCreateDisabled: Self.isCreateDisabled(
                                hasSpecialist: selectedSpecialist != nil,
                                isCreating: isCreating,
                                isLoadingProviders: isLoadingProviders,
                                isLoadingModels: isLoadingModels,
                                providers: providers
                            ),
                            colorScheme: colorScheme,
                            onCreate: createSelectedAgent
                        )
                        .alert("Error", isPresented: $showError) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(errorMessage ?? "An unknown error occurred.")
                        }
                        .task { await fetchProviders() }
                        .onChange(of: selectedProvider?.id) { _, _ in
                            if let provider = selectedProvider {
                                Task { await fetchModels(for: provider) }
                            } else {
                                models = []
                                selectedModel = nil
                            }
                        }
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
        .onChange(of: agentName) {
            if isSettingNameFromSpecialist {
                isSettingNameFromSpecialist = false
            } else {
                userEditedName = true
            }
        }
    }

    private func fetchSpecialists() async {
        specialists = await agentStore.fetchSpecialists().modalPickable
        isLoadingSpecialists = false
        // Default to the resolved orchestrator (PROTOCOL §5.11 role metadata),
        // falling back to the first pickable specialist (matches CreateWorkspaceView).
        if selectedSpecialist == nil,
           let defaultSpecialist = specialists.orchestrator ?? specialists.first {
            selectedSpecialist = defaultSpecialist
            isSettingNameFromSpecialist = true
            agentName = defaultSpecialist.name
        }
    }

    private func fetchProviders() async {
        isLoadingProviders = true
        let fetched = await agentStore.fetchProviders()
        providers = fetched
        selectedProvider = Self.resolveProviderSelection(current: selectedProvider, providers: fetched)
        isLoadingProviders = false
    }

    private func fetchModels(for provider: ProviderInfo) async {
        modelFetchGeneration += 1
        let generation = modelFetchGeneration
        isLoadingModels = true
        selectedModel = nil
        let fetched = await agentStore.fetchModels(providerId: provider.id)
        guard let outcome = Self.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: provider.id,
            selectedProviderId: selectedProvider?.id,
            requestGeneration: generation,
            latestGeneration: modelFetchGeneration
        ) else { return }
        isLoadingModels = outcome.isLoadingModels
        guard let applied = outcome.models else { return }
        models = applied
        selectedModel = outcome.selectedModel
    }

    private func selectSpecialist(_ specialist: SpecialistInfo) {
        selectedSpecialist = specialist
        if !userEditedName {
            isSettingNameFromSpecialist = true
            agentName = specialist.name
        }
    }

    private func createSelectedAgent() {
        if let specialist = selectedSpecialist {
            createAgentWithSpecialist(specialist)
        }
    }

    private func createAgentWithSpecialist(_ specialist: SpecialistInfo) {
        guard !isCreating else { return }
        isCreating = true

        Task { @MainActor in
            do {
                let selection = Self.buildCreateAgentSelection(
                    provider: selectedProvider,
                    model: selectedModel
                )
                let agent = try await agentStore.createAgent(
                    workspaceId: workspaceId,
                    specialistId: specialist.id,
                    name: agentName.isEmpty ? nil : agentName,
                    provider: selection.provider,
                    model: selection.model
                )
                HapticManager.notification(.success)
                dismiss()
                if let agent {
                    coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
                }
            } catch {
                AppLog.agents.error("[SpecialistPicker] Failed to create agent: \(error)")
                errorMessage = error.localizedDescription
                showError = true
            }
            isCreating = false
        }
    }
}
