import SwiftUI

struct ModelPickerView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let models = viewModel.selectableModels {
                    modelList(models)
                } else if viewModel.modelCatalogLoadFailed {
                    loadFailedState
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Select Model")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await viewModel.refreshSelectableModels()
            }
        }
    }

    /// The provider's `models.list` failed and nothing is cached: an
    /// explicit retry instead of an indefinite spinner.
    private var loadFailedState: some View {
        ContentUnavailableView {
            Label("Models Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The model list could not be loaded.")
        } actions: {
            Button("Retry") {
                Task { await viewModel.refreshSelectableModels() }
            }
        }
    }

    private func modelList(_ models: [ModelInfo]) -> some View {
        List {
            let grouped = Dictionary(grouping: models, by: \.provider)
            let sortedProviders = grouped.keys.sorted()

            ForEach(sortedProviders, id: \.self) { provider in
                Section(header: Text(provider)) {
                    if let models = grouped[provider] {
                        ForEach(models) { model in
                            Button {
                                Task {
                                    await viewModel.setModel(model.id)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    Text(model.name)
                                        .foregroundStyle(Theme.foreground(for: colorScheme))
                                    Spacer()
                                    if viewModel.currentModelId == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.primary(for: colorScheme))
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
