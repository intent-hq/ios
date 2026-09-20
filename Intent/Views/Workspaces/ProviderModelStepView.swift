import SwiftUI

struct ProviderModelStepView: View {
    let providers: [ProviderInfo]
    let isLoadingProviders: Bool
    @Binding var selectedProvider: ProviderInfo?
    let models: [ModelInfo]
    let isLoadingModels: Bool
    @Binding var selectedModel: ModelInfo?
    let selectedSpecialist: SpecialistInfo?
    let isCreating: Bool
    let isCreateDisabled: Bool
    let colorScheme: ColorScheme
    let onCreate: () -> Void

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            providerContent
            creatingOverlay
        }
        .navigationTitle("Provider & Model")
        .toolbarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isCreating)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create", action: onCreate)
                    .disabled(isCreateDisabled)
                    .fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private var providerContent: some View {
        if isLoadingProviders {
            ProgressView("Loading providers...")
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        } else if providers.noneSelectable {
            noSelectableProvidersList
        } else {
            providerAndModelList
        }
    }

    private var noSelectableProvidersList: some View {
        List {
            Section("Provider") {
                noProvidersSignedInPlaceholder
                    .listRowBackground(Theme.card(for: colorScheme))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var providerAndModelList: some View {
        List {
            providerSection
            modelSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var providerSection: some View {
        Section("Provider") {
            if providers.isEmpty {
                Text("No providers found — the default provider will be used.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .listRowBackground(Theme.card(for: colorScheme))
            } else {
                providerPicker
            }
        }
    }

    private var providerPicker: some View {
        Picker("Provider", selection: Binding(
            get: { selectedProvider?.id ?? "" },
            set: { newId in selectProvider(newId) }
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

    private func selectProvider(_ newId: String) {
        guard let provider = providers.first(where: { $0.id == newId }),
              SpecialistPickerView.isSelectable(provider) else { return }
        selectedProvider = provider
    }

    @ViewBuilder
    private var modelSection: some View {
        Section("Model") {
            if isLoadingModels {
                modelLoadingIndicator
            } else if models.isEmpty {
                Text("The provider's default model will be used.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .listRowBackground(Theme.card(for: colorScheme))
            } else {
                modelPicker
            }
        }
    }

    private var modelLoadingIndicator: some View {
        HStack(spacing: Constants.ModalPicker.modelLoadingSpacing) {
            ProgressView().controlSize(.small)
            Text("Loading models...")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .listRowBackground(Theme.card(for: colorScheme))
    }

    private var modelPicker: some View {
        Picker("Model", selection: Binding(
            get: { selectedModel?.id ?? "" },
            set: { newId in selectedModel = models.first { $0.id == newId } }
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

    @ViewBuilder
    private var creatingOverlay: some View {
        if isCreating {
            Color.black.opacity(Constants.ModalPicker.loadingOverlayOpacity).ignoresSafeArea()
            VStack(spacing: Constants.ModalPicker.loadingOverlaySpacing) {
                ProgressView()
                Text("Creating agent...")
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .padding(Constants.ModalPicker.loadingOverlayPadding)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Constants.ModalPicker.loadingOverlayCornerRadius))
        }
    }

    /// Guidance shown when providers exist but none are signed in; provider
    /// sign-in flows run on the desktop seat and are not available on iOS.
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
}
