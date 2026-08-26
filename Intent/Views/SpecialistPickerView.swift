import SwiftUI

struct SpecialistPickerView: View {
    let workspaceId: String
    var agentStore: AgentStore
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
    @State private var modelFetchGeneration = 0
    @State private var selectedModel: ModelInfo?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false

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
            } else if providers.noneSelectable {
                // No selectable provider: replace the Provider picker (and the
                // dependent Model section) with desktop-setup guidance instead
                // of rendering a menu with no valid selection (monorepo#985).
                List {
                    Section("Provider") {
                        noProvidersSignedInPlaceholder
                            .listRowBackground(Theme.card(for: colorScheme))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
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
                            // The daemon-default row (empty tag) keeps
                            // selectedModel nil; a model is sent only on an
                            // explicit user pick.
                            Picker("Model", selection: Binding(
                                get: { selectedModel?.id ?? "" },
                                set: { newId in
                                    selectedModel = models.first(where: { $0.id == newId })
                                }
                            )) {
                                Text(SpecialistInfo.daemonDefaultLabel(
                                    for: selectedSpecialist,
                                    providerId: selectedProvider?.id
                                )).tag("")
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
                .disabled(Self.isCreateDisabled(
                    hasSpecialist: selectedSpecialist != nil,
                    isCreating: isCreating,
                    isLoadingProviders: isLoadingProviders,
                    isLoadingModels: isLoadingModels,
                    providers: providers
                ))
                .fontWeight(.semibold)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
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

    /// Guidance shown when providers exist but none are signed in; provider
    /// sign-in flows run on the desktop seat and are not available on iOS.
    private var noProvidersSignedInPlaceholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No providers are signed in")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Set up a provider in the Intent desktop app, then come back and try again.")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Selection helpers (testable)

    /// Providers with `authenticated == false` are not selectable;
    /// `nil` (unknown) stays selectable since probes can fail transiently.
    static func isSelectable(_ provider: ProviderInfo) -> Bool {
        provider.isSelectable
    }

    /// The Create action is unavailable while no specialist is selected, a
    /// create is in flight, providers/models are still loading, or no provider
    /// is selectable — the desktop-setup guidance state, where submission
    /// would only fail daemon-side (monorepo#1003).
    static func isCreateDisabled(
        hasSpecialist: Bool,
        isCreating: Bool,
        isLoadingProviders: Bool,
        isLoadingModels: Bool,
        providers: [ProviderInfo]
    ) -> Bool {
        !hasSpecialist || isCreating || isLoadingProviders || isLoadingModels || providers.noneSelectable
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

    /// Outcome of a completed model fetch, or nil when a newer fetch has
    /// been started since (`requestGeneration != latestGeneration`): a
    /// superseded response must be ignored entirely — it must not clear
    /// `isLoadingModels` while the newer fetch is still in flight, or the
    /// previous provider's catalog could briefly present as the current
    /// one and allow a mismatched (provider, model) pair on create.
    /// For the latest generation, a provider mismatch (the selection was
    /// cleared while the fetch was in flight) returns nil `models` so the
    /// current catalog is kept, but `isLoadingModels` still clears — the
    /// Create button is disabled while it is set. A fresh catalog always
    /// resets the selection to the daemon-default row (nil) — the daemon's
    /// resolver decides unless the user explicitly picks a model.
    static func modelFetchOutcome(
        fetched: [ModelInfo],
        requestedProviderId: String,
        selectedProviderId: String?,
        requestGeneration: Int,
        latestGeneration: Int
    ) -> (models: [ModelInfo]?, selectedModel: ModelInfo?, isLoadingModels: Bool)? {
        guard requestGeneration == latestGeneration else { return nil }
        guard selectedProviderId == requestedProviderId else {
            return (nil, nil, false)
        }
        return (fetched, nil, false)
    }

    /// Builds the provider/model params for `agent.create`. `model` is
    /// non-nil only on an explicit user pick — the daemon-default picker row
    /// keeps it nil so the daemon's resolver decides. For auggie (the daemon
    /// default) the provider is omitted, matching CreateWorkspaceView's
    /// omission logic.
    static func buildCreateAgentSelection(
        provider: ProviderInfo?,
        model: ModelInfo?
    ) -> (provider: String?, model: String?) {
        let providerId = provider?.id
        return (providerId == "auggie" ? nil : providerId, model?.id)
    }

    @ViewBuilder
    private func specialistRow(_ specialist: SpecialistInfo) -> some View {
        HStack(spacing: 12) {
            AgentAvatarView(agentId: specialist.id, size: 28, specialist: specialist.id)

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
                if let agent = agent {
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

