import SwiftUI

struct ModelPickerView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                let grouped = Dictionary(grouping: viewModel.availableModels, by: \.provider)
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
                                                .accessibilityLabel("Selected model")
                                        }
                                    }
                                }
                            }
                        }
                    }
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
                await viewModel.fetchModels()
            }
        }
    }
}
