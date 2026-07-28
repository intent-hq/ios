import SwiftUI

struct SpecialistPickerView: View {
    let workspaceId: String
    @ObservedObject var agentStore: AgentStore
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    // Navigation state
    @State private var navigationPath = NavigationPath()

    // Step 1: Name + specialist
    @State private var specialists: [SpecialistInfo] = []
    @State private var isLoadingSpecialists = true
    @State private var selectedSpecialist: SpecialistInfo?
    @State private var agentName: String = ""
    @State private var userEditedName: Bool = false
    @State private var isSettingNameFromSpecialist: Bool = false

    // Step 2: Provider + model
    @State private var providers: [ProviderInfo] = []
    @State private var isLoadingProviders = true
    @State private var selectedProvider: ProviderInfo?
    @State private var models: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var selectedModel: ModelInfo?
    @State private var isCreating = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            specialistStepView
                .navigationDestination(for: String.self) { step in
                    if step == "provider" {
                        providerStepView
                    }
                }
        }
        .onChange(of: agentName) {
            if isSettingNameFromSpecialist {
                isSettingNameFromSpecialist = false
            } else {
                userEditedName = true
            }
        }
    }

    // MARK: - Step 1: Name + Specialist

    private var specialistStepView: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoadingSpecialists {
                ProgressView("Loading specialists...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if specialists.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.rectangle.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    Text("No specialists available")
                        .font(.headline)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            } else {
                List {
                    Section("Name") {
                        TextField("Agent name", text: $agentName)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                    }
                    .listRowBackground(Theme.card(for: colorScheme))

                    ForEach(specialists) { specialist in
                        Button {
                            selectedSpecialist = specialist
                            if !userEditedName {
                                isSettingNameFromSpecialist = true
                                agentName = specialist.name
                            }
                        } label: {
                            specialistRow(specialist)
                        }
                        .listRowBackground(Theme.card(for: colorScheme))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("New Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next") {
                    navigationPath.append("provider")
                }
                .disabled(selectedSpecialist == nil)
                .fontWeight(.semibold)
            }
        }
        .task {
            specialists = await agentStore.fetchSpecialists().pickable
            isLoadingSpecialists = false
            // Default to Coordinator specialist, falling back to the first
            // pickable specialist (matches CreateWorkspaceView)
            if selectedSpecialist == nil,
               let defaultSpecialist = specialists.first(where: { $0.id == "spec-writer" }) ?? specialists.first {
                selectedSpecialist = defaultSpecialist
                isSettingNameFromSpecialist = true
                agentName = defaultSpecialist.name
            }
        }
    }

    // MARK: - Step 2: Provider + Model

    private var providerStepView: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoadingProviders {
                ProgressView("Loading providers...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else {
                List {
                    Section("Provider") {
                        if providers.isEmpty {
                            Text("No providers found — the default provider will be used.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .listRowBackground(Theme.card(for: colorScheme))
                        } else {
                            Picker("Provider", selection: Binding(
                                get: { selectedProvider?.id ?? "" },
                                set: { newId in
                                    // Unauthenticated providers can never become the
                                    // selection; the onChange handler refetches models
                                    guard let provider = providers.first(where: { $0.id == newId }),
                                          Self.isSelectable(provider) else { return }
                                    selectedProvider = provider
                                }
                            )) {
                                ForEach(providers) { provider in
                                    Text(provider.authenticated == false
                                        ? "\(provider.displayName) (not signed in)"
                                        : provider.displayName)
                                        .tag(provider.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(isCreating)
                            .listRowBackground(Theme.card(for: colorScheme))
                        }
                    }

                    Section("Model") {
                        if isLoadingModels {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading models...")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            }
                            .listRowBackground(Theme.card(for: colorScheme))
                        } else if models.isEmpty {
                            Text("The provider's default model will be used.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .listRowBackground(Theme.card(for: colorScheme))
                        } else {
                            Picker("Model", selection: Binding(
                                get: { selectedModel?.id ?? "" },
                                set: { newId in
                                    selectedModel = models.first(where: { $0.id == newId })
                                }
                            )) {
                                ForEach(models) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .listRowBackground(Theme.card(for: colorScheme))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }

            if isCreating {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Creating agent...")
                        .font(.subheadline)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("Provider & Model")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isCreating)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create") {
                    if let specialist = selectedSpecialist {
                        createAgentWithSpecialist(specialist)
                    }
                }
                .disabled(selectedSpecialist == nil || isCreating || isLoadingProviders || isLoadingModels)
                .fontWeight(.semibold)
            }
        }
        .task {
            await fetchProviders()
        }
        .onChange(of: selectedProvider?.id) { _, _ in
            if let provider = selectedProvider {
                Task { await fetchModels(for: provider) }
            } else {
                models = []
                selectedModel = nil
            }
        }
    }

    // MARK: - Data Fetching

    private func fetchProviders() async {
        isLoadingProviders = true
        let fetched = await agentStore.fetchProviders()
        providers = fetched
        selectedProvider = Self.resolveProviderSelection(current: selectedProvider, providers: fetched)
        isLoadingProviders = false
    }

    private func fetchModels(for provider: ProviderInfo) async {
        isLoadingModels = true
        selectedModel = nil
        let fetched = await agentStore.fetchModels(providerId: provider.id)
        let outcome = Self.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: provider.id,
            selectedProviderId: selectedProvider?.id,
            specialist: selectedSpecialist
        )
        isLoadingModels = outcome.isLoadingModels
        guard let applied = outcome.models else { return }
        models = applied
        selectedModel = outcome.selectedModel
    }

    // MARK: - Selection helpers (testable)

    /// Providers with `authenticated == false` are not selectable;
    /// `nil` (unknown) stays selectable since probes can fail transiently.
    static func isSelectable(_ provider: ProviderInfo) -> Bool {
        provider.authenticated != false
    }

    /// Keeps the current selection when it is still selectable, otherwise falls
    /// back to auggie if selectable, else the first selectable provider.
    static func resolveProviderSelection(current: ProviderInfo?, providers: [ProviderInfo]) -> ProviderInfo? {
        let selectable = providers.filter { isSelectable($0) }
        if let current = current, let updated = selectable.first(where: { $0.id == current.id }) {
            return updated
        }
        return selectable.first(where: { $0.id == "auggie" }) ?? selectable.first
    }

    /// The auggie model id a specialist resolves to by default: its configured
    /// model, else the tier default (shared with CreateWorkspaceView via
    /// `SpecialistInfo.modelId(forTier:)`).
    static func defaultAuggieModelId(for specialist: SpecialistInfo?) -> String {
        specialist?.model ?? SpecialistInfo.modelId(forTier: specialist?.modelTier)
    }

    /// Outcome of a completed model fetch. Stale fetches (the selected
    /// provider changed — or was cleared — while the fetch was in flight)
    /// return nil `models` so the current catalog is kept, but
    /// `isLoadingModels` is always false: no newer fetch may take over the
    /// flag (e.g. a provider refresh resolved the selection to nil) and the
    /// Create button is disabled while it is set.
    static func modelFetchOutcome(
        fetched: [ModelInfo],
        requestedProviderId: String,
        selectedProviderId: String?,
        specialist: SpecialistInfo?
    ) -> (models: [ModelInfo]?, selectedModel: ModelInfo?, isLoadingModels: Bool) {
        guard selectedProviderId == requestedProviderId else {
            return (nil, nil, false)
        }
        let selection = defaultModel(in: fetched, providerId: requestedProviderId, specialist: specialist)
        return (fetched, selection, false)
    }

    /// Default model selection for a provider's catalog: for auggie, the
    /// specialist's default model when present in the catalog; otherwise the
    /// provider-reported default (`isDefault`), else the first model.
    static func defaultModel(in models: [ModelInfo], providerId: String?, specialist: SpecialistInfo?) -> ModelInfo? {
        if providerId == "auggie",
           let match = models.first(where: { $0.id == defaultAuggieModelId(for: specialist) }) {
            return match
        }
        return models.first(where: { $0.isDefault }) ?? models.first
    }

    /// Builds the provider/model params for `agent.create`. For auggie (the
    /// daemon default) the provider is always omitted: both are omitted when
    /// the model matches the specialist's default (letting the daemon's model
    /// resolution win), and only the bare `model` is sent on an override —
    /// matching CreateWorkspaceView's omission logic.
    static func buildCreateAgentSelection(
        specialist: SpecialistInfo?,
        provider: ProviderInfo?,
        model: ModelInfo?
    ) -> (provider: String?, model: String?) {
        guard let provider = provider else { return (nil, nil) }
        if provider.id == "auggie" {
            guard let model = model, model.id != defaultAuggieModelId(for: specialist) else {
                return (nil, nil)
            }
            return (nil, model.id)
        }
        return (provider.id, model?.id)
    }

    @ViewBuilder
    private func specialistRow(_ specialist: SpecialistInfo) -> some View {
        HStack(spacing: 12) {
            AuggieAvatarView(seed: specialist.id, size: 28, specialist: specialist.id)

            VStack(alignment: .leading, spacing: 4) {
                Text(specialist.name)
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text(specialist.description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .lineLimit(2)
            }

            Spacer()

            if selectedSpecialist?.id == specialist.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.primary(for: colorScheme))
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func createAgentWithSpecialist(_ specialist: SpecialistInfo) {
        guard !isCreating else { return }
        isCreating = true

        Task {
            do {
                let selection = Self.buildCreateAgentSelection(
                    specialist: specialist,
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
                if let agent = agent {
                    coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
                }
            } catch {
                print("[SpecialistPicker] Failed to create agent: \(error)")
            }
            isCreating = false
        }
    }
}

