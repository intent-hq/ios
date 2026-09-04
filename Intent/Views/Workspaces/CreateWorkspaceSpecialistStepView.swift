import SwiftUI

struct CreateWorkspaceSpecialistStepView: View {
    let specialists: [SpecialistInfo]
    let isLoadingSpecialists: Bool
    @Binding var selectedSpecialist: SpecialistInfo?
    let providers: [ProviderInfo]
    let isLoadingProviders: Bool
    @Binding var selectedProvider: ProviderInfo?
    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    @Binding var messageText: String
    let isCreating: Bool
    let errorMessage: String?
    @Binding var showError: Bool
    let colorScheme: ColorScheme
    let onSelectProvider: (ProviderInfo) -> Void
    let onCreate: () -> Void
    let onLoad: () async -> Void

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            if isLoadingSpecialists {
                ProgressView("Loading...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else {
                optionsList
            }
            if isCreating {
                creatingOverlay
            }
        }
        .navigationTitle("Create Workspace")
        .toolbarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isCreating)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create", action: onCreate)
                    .disabled(CreateWorkspaceView.isCreateDisabled(
                        isCreating: isCreating,
                        isLoadingProviders: isLoadingProviders,
                        providers: providers
                    ))
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .task { await onLoad() }
    }

    private var optionsList: some View {
        List {
            Section("Initial Message (Optional)") {
                TextField("Describe what you'd like to do...", text: $messageText, axis: .vertical)
                    .lineLimit(Constants.CreateWorkspace.messageLineCountRange)
                    .font(.body)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .listRowBackground(Theme.card(for: colorScheme))
            }
            Section("Specialist") {
                specialistPicker
            }
            if providers.noneSelectable {
                Section("Provider") {
                    noProvidersSignedInPlaceholder
                        .listRowBackground(Theme.card(for: colorScheme))
                }
            } else if !providers.isEmpty {
                Section("Provider") {
                    providerPicker
                }
            }
            if !models.isEmpty {
                Section("Model") {
                    modelPicker
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var specialistPicker: some View {
        Picker("Specialist", selection: Binding(
            get: { selectedSpecialist?.id ?? "" },
            set: { id in selectedSpecialist = specialists.first(where: { $0.id == id }) }
        )) {
            ForEach(specialists) { specialist in
                Text(specialist.name).tag(specialist.id)
            }
        }
        .pickerStyle(.menu)
        .listRowBackground(Theme.card(for: colorScheme))
    }

    private var providerPicker: some View {
        Picker("Provider", selection: Binding(
            get: { selectedProvider?.id ?? "" },
            set: { id in
                if let provider = providers.first(where: { $0.id == id }) {
                    onSelectProvider(provider)
                }
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
        .listRowBackground(Theme.card(for: colorScheme))
    }

    private var modelPicker: some View {
        Picker("Model", selection: Binding(
            get: { selectedModel?.id ?? "" },
            set: { id in selectedModel = models.first(where: { $0.id == id }) }
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

    private var noProvidersSignedInPlaceholder: some View {
        VStack(alignment: .leading, spacing: Constants.ModalPicker.placeholderSpacing) {
            Text("No providers are signed in")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Set up a provider in the Intent desktop app, then come back and try again.")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.vertical, Constants.ModalPicker.rowVerticalPadding)
    }

    private var creatingOverlay: some View {
        Group {
            Color.black.opacity(Constants.ModalPicker.loadingOverlayOpacity).ignoresSafeArea()
            VStack(spacing: Constants.ModalPicker.loadingOverlaySpacing) {
                ProgressView()
                Text("Cloning repository…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .padding(Constants.ModalPicker.loadingOverlayPadding)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Constants.ModalPicker.loadingOverlayCornerRadius))
        }
    }
}

extension CreateWorkspaceView {
    static func isCreateDisabled(isCreating: Bool, isLoadingProviders: Bool, providers: [ProviderInfo]) -> Bool {
        isCreating || isLoadingProviders || providers.noneSelectable
    }

    static func buildCreateWorkspaceParams(
        githubUrl: String,
        baseRef: String,
        idempotencyKey: String,
        specialist: SpecialistInfo?,
        provider: ProviderInfo? = nil,
        model: ModelInfo?,
        message: String
    ) -> [String: Any] {
        var params: [String: Any] = [
            "githubUrl": githubUrl,
            "baseRef": baseRef,
            "idempotencyKey": idempotencyKey
        ]
        let isNonAuggieProvider = provider.map { $0.id != "auggie" } ?? false
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = !trimmedMessage.isEmpty
        if specialist != nil || hasMessage || model != nil || isNonAuggieProvider {
            var initialAgent: [String: Any] = [:]
            if let specialist { initialAgent["specialist"] = specialist.id }
            if isNonAuggieProvider, let provider { initialAgent["provider"] = provider.id }
            if let model { initialAgent["model"] = model.id }
            if hasMessage { initialAgent["prompt"] = trimmedMessage }
            params["initialAgent"] = initialAgent
        }
        return params
    }

    static func modelFetchOutcome(
        fetched: [ModelInfo],
        requestedProviderId: String,
        selectedProviderId: String?
    ) -> (models: [ModelInfo], selectedModel: ModelInfo?)? {
        guard selectedProviderId == requestedProviderId else { return nil }
        return (fetched, nil)
    }
}