import SwiftUI

struct SpecialistPickerView: View {
    private enum Route: Hashable {
        case provider
    }

    let workspaceId: String
    var agentStore: AgentStore
    /// The session-owned specialist / provider / model cache: it outlives
    /// this sheet so a reopen renders the cached lists instantly while the
    /// store revalidates in the background (same wiring as
    /// `CreateWorkspaceView`).
    var optionsStore: CreationOptionsStore
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var navigationPath: [Route] = []

    @State private var selectedSpecialist: SpecialistInfo?
    @State private var agentName: String = ""
    @State private var userEditedName: Bool = false
    @State private var isSettingNameFromSpecialist: Bool = false
    /// Which of this sheet's own loads returned (options; models per
    /// provider), so a settled load that failed shows the empty state or the
    /// daemon-default row instead of spinning forever — published only for
    /// loads that returned in the store generation they started in.
    @State private var settledLoads = SettledLoads()

    @State private var selectedProvider: ProviderInfo?
    @State private var selectedModel: ModelInfo?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false

    /// Pickable specialists in daemon order (`modalPickable`).
    private var specialists: [SpecialistInfo] { optionsStore.specialists.modalPickable }
    private var providers: [ProviderInfo] { optionsStore.providers }
    /// The selected provider's cached catalog; empty until loaded. An
    /// older provider's response can only land in its own cache slot, so
    /// it never presents as the current selection's list.
    private var models: [ModelInfo] {
        selectedProvider.flatMap { optionsStore.models(for: $0.id) } ?? []
    }
    /// Derived from the store, never a local snapshot: a cache that warms
    /// between construction and the step's load drops the loading state on
    /// its own, and a reconnect clear drives it back on while the store
    /// reloads cold.
    private var isLoadingOptions: Bool {
        CreateWorkspaceView.showsOptionsLoading(
            storeIsLoading: optionsStore.isLoading,
            storeHasLoaded: optionsStore.hasLoaded,
            settled: settledLoads.options
        )
    }
    private var isLoadingModels: Bool {
        guard let provider = selectedProvider else { return false }
        return Self.showsModelsLoading(
            catalog: optionsStore.models(for: provider.id),
            settled: settledLoads.modelProviders.contains(provider.id)
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            specialistStep
                .navigationDestination(for: Route.self) { destination(for: $0) }
        }
        .interactiveDismissDisabled(isCreating)
        .onChange(of: agentName) { handleAgentNameChange() }
        // A background revalidation or reconnect reload swaps the cached
        // lists under the open sheet: keep the selections valid against
        // them. Observed by value, not by id, so a same-id metadata change
        // (a provider signing out, a specialist turning hidden) reconciles.
        .onChange(of: optionsStore.specialists) { _, _ in
            reconcileSpecialistSelection()
        }
        .onChange(of: optionsStore.providers) { _, _ in
            Task { await reconcileProviderSelection() }
        }
        .onChange(of: models) { _, models in
            selectedModel = CreateWorkspaceView.reconciledModel(current: selectedModel, models: models)
        }
        // A user pick in the Provider menu: an explicit model never survives
        // a provider switch; the new provider's catalog is instant when
        // cached, loaded cold otherwise.
        .onChange(of: selectedProvider?.id) { _, _ in
            selectedModel = nil
            if let provider = selectedProvider {
                Task { await loadModels(for: provider) }
            }
        }
        // A reconnect hard-clears the store: reload (joining the store's own
        // cold reload) and re-warm the selected provider's catalog so the
        // open step never sits loading forever on a cleared cache.
        .onChange(of: optionsStore.loadGeneration) { _, _ in
            settledLoads.reset()
            Task {
                await loadOptions()
                if navigationPath.contains(.provider) {
                    await reconcileProviderSelection()
                }
            }
        }
    }

    private var specialistStep: some View {
        SpecialistStepView(
            specialists: specialists,
            isLoadingSpecialists: isLoadingOptions,
            selectedSpecialist: selectedSpecialist,
            agentName: $agentName,
            colorScheme: colorScheme,
            onSelect: selectSpecialist,
            onDismiss: { dismiss() },
            onNext: { navigationPath.append(.provider) }
        )
        .task { await loadOptions() }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .provider:
            providerModelStep
        }
    }

    private var providerModelStep: some View {
        ProviderModelStepView(
            providers: providers,
            isLoadingProviders: isLoadingOptions,
            selectedProvider: $selectedProvider,
            models: models,
            isLoadingModels: isLoadingModels,
            selectedModel: $selectedModel,
            selectedSpecialist: selectedSpecialist,
            isCreating: isCreating,
            isCreateDisabled: Self.isCreateDisabled(
                hasSpecialist: selectedSpecialist != nil,
                isCreating: isCreating,
                isLoadingProviders: isLoadingOptions,
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
        .task {
            await loadOptions()
            await reconcileProviderSelection()
        }
    }

    private func handleAgentNameChange() {
        if isSettingNameFromSpecialist {
            isSettingNameFromSpecialist = false
        } else {
            userEditedName = true
        }
    }

    /// Cold (nothing cached): awaits the specialist/provider load while
    /// `isLoadingOptions` shows. Cached: the steps already render the cached
    /// lists — the store revalidates in the background and no spinner shows.
    /// A load superseded by a reconnect clear publishes nothing: the
    /// `loadGeneration` change starts a fresh load that settles and reconciles.
    private func loadOptions() async {
        let generation = optionsStore.loadGeneration
        await optionsStore.loadIfNeeded()
        guard settledLoads.settleOptions(startedAt: generation, current: optionsStore.loadGeneration) else {
            return
        }
        reconcileSpecialistSelection()
    }

    /// Defaults the specialist selection (orchestrator, else first pickable)
    /// and re-defaults or clears it when the selected specialist left the
    /// pickable set; a changed selection renames the agent unless the user
    /// already edited the name.
    private func reconcileSpecialistSelection() {
        let previousId = selectedSpecialist?.id
        selectedSpecialist = Self.reconciledSpecialist(
            current: selectedSpecialist,
            catalog: optionsStore.specialists
        )
        guard let specialist = selectedSpecialist, specialist.id != previousId, !userEditedName else { return }
        applyName(from: specialist)
    }

    /// Defaults the provider selection to a selectable provider (auggie
    /// first) and loads its model catalog — instant when cached, awaited
    /// when cold. An explicit model never survives a provider switch.
    private func reconcileProviderSelection() async {
        let previousProviderId = selectedProvider?.id
        selectedProvider = CreateWorkspaceView.preselectedProvider(
            current: selectedProvider,
            providers: providers
        )
        guard let provider = selectedProvider else {
            selectedModel = nil
            return
        }
        if provider.id != previousProviderId { selectedModel = nil }
        await loadModels(for: provider)
    }

    private func loadModels(for provider: ProviderInfo) async {
        let generation = optionsStore.loadGeneration
        await optionsStore.loadModelsIfNeeded(providerId: provider.id)
        settledLoads.settleModels(
            for: provider.id,
            startedAt: generation,
            current: optionsStore.loadGeneration
        )
    }

    private func selectSpecialist(_ specialist: SpecialistInfo) {
        selectedSpecialist = specialist
        if !userEditedName {
            applyName(from: specialist)
        }
    }

    /// `onChange(of: agentName)` only fires on a real change, so the
    /// "programmatic write" flag is armed only when the name changes —
    /// otherwise it would swallow the user's next edit.
    private func applyName(from specialist: SpecialistInfo) {
        guard specialist.name != agentName else { return }
        isSettingNameFromSpecialist = true
        agentName = specialist.name
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
