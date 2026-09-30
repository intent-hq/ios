import SwiftUI

struct ProviderModelStepView: View {
    let providers: [ProviderInfo]
    let isLoadingProviders: Bool
    let providerGuidance: String?
    @Binding var selectedProvider: ProviderInfo?
    let models: [ModelInfo]
    let isLoadingModels: Bool
    @Binding var selectedModel: ModelInfo?
    let selectedSpecialist: SpecialistInfo?
    let isCreating: Bool
    let isCreateDisabled: Bool
    let colorScheme: ColorScheme
    let onRetryProviders: () -> Void
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
                    .interFont(Constants.Typography.bodyS.withFace(.semibold))
            }
        }
    }

    @ViewBuilder
    private var providerContent: some View {
        if isLoadingProviders {
            ProgressView {
                Text("Loading providers...").interFont(Constants.Typography.bodyS)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        } else if let providerGuidance {
            List {
                Section {
                    Text(providerGuidance)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    Button("Retry", action: onRetryProviders)
                        .interFont(Constants.Typography.bodyS)
                }
                .listRowBackground(Theme.card(for: colorScheme))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else if providers.noneSelectable {
            noSelectableProvidersList
        } else {
            providerAndModelList
        }
    }

    private var noSelectableProvidersList: some View {
        List {
            Section {
                noProvidersSignedInPlaceholder
                    .listRowBackground(Theme.card(for: colorScheme))
            } header: {
                Text("Provider").interFont(Constants.Typography.eyebrow)
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
        Section {
            providerPicker
        } header: {
            Text("Provider").interFont(Constants.Typography.eyebrow)
        }
    }

    private var providerPicker: some View {
        ProviderPicker(
            providers: providers,
            selectedProvider: selectedProvider,
            onSelect: selectProvider
        )
        .disabled(isCreating)
        .listRowBackground(Theme.card(for: colorScheme))
    }

    private func selectProvider(_ provider: ProviderInfo) {
        guard providers.contains(provider), provider.isSelectable, provider.id != selectedProvider?.id else { return }
        selectedModel = nil
        selectedProvider = provider
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            if isLoadingModels {
                modelLoadingIndicator
            } else if models.isEmpty {
                Text("The provider's default model will be used.")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .listRowBackground(Theme.card(for: colorScheme))
            } else {
                modelPicker
            }
        } header: {
            Text("Model").interFont(Constants.Typography.eyebrow)
        }
    }

    private var modelLoadingIndicator: some View {
        HStack(spacing: Constants.ModalPicker.modelLoadingSpacing) {
            ProgressView().controlSize(.small)
            Text("Loading models...")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .listRowBackground(Theme.card(for: colorScheme))
    }

    private var modelPicker: some View {
        ModelPicker(
            models: models,
            selectedModel: $selectedModel,
            daemonDefaultLabel: SpecialistInfo.daemonDefaultLabel(
                for: selectedSpecialist,
                providerId: selectedProvider?.id
            )
        )
        .listRowBackground(Theme.card(for: colorScheme))
    }

    @ViewBuilder
    private var creatingOverlay: some View {
        if isCreating {
            Color.black.opacity(Constants.ModalPicker.loadingOverlayOpacity).ignoresSafeArea()
            VStack(spacing: Constants.ModalPicker.loadingOverlaySpacing) {
                ProgressView()
                Text("Creating agent...")
                    .interFont(Constants.Typography.bodyXS)
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
                .interFont(Constants.Typography.bodyXS.withFace(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Set up a provider in the Intent desktop app, then come back and try again.")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.vertical, Constants.ModalPicker.rowVerticalPadding)
    }
}
