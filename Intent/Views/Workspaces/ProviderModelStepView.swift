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
                                    // selection; the parent refetches models on change.
                                    guard let provider = providers.first(where: { $0.id == newId }),
                                          SpecialistPickerView.isSelectable(provider) else { return }
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
                            HStack(spacing: Constants.ModalPicker.modelLoadingSpacing) {
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
                            // The daemon-default row (empty tag) keeps selectedModel
                            // nil; a model is sent only on an explicit user pick.
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