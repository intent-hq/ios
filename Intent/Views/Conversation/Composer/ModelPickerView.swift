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
            Label {
                Text("Models Unavailable").interFont(Constants.Typography.bodyM)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
        } description: {
            Text("The model list could not be loaded.")
                .interFont(Constants.Typography.bodyXS)
        } actions: {
            Button("Retry") {
                Task { await viewModel.refreshSelectableModels() }
            }
            .interFont(Constants.Typography.bodyS)
        }
    }

    private func modelList(_ models: [ModelInfo]) -> some View {
        List {
            let grouped = Dictionary(grouping: models, by: \.provider)
            let sortedProviders = grouped.keys.sorted()

            ForEach(sortedProviders, id: \.self) { provider in
                Section(header: Text(provider).interFont(Constants.Typography.eyebrow)) {
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
                                        .interFont(Constants.Typography.bodyS)
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
