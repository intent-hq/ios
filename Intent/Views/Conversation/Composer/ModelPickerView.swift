import SwiftUI

struct ModelPickerView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    @ScaledMetric(relativeTo: .body) private var selectionIconSide: CGFloat = 17

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
                    IntentIconButton(icon: .close, label: "Cancel") { dismiss() }
                }
                .intentToolbarSurface()
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
            .buttonStyle(IntentButtonStyle())
            .interFont(Constants.Typography.bodyS)
        }
    }

    private func modelList(_ models: [ModelInfo]) -> some View {
        let selectedModelId = viewModel.currentModelId
        let grouped = Dictionary(grouping: models, by: \.provider)
        let sections = grouped.keys.sorted().map { provider in
            let rows = (grouped[provider] ?? []).map { model in
                (id: model.id, content: modelButton(model, isSelected: selectedModelId == model.id))
            }
            let section = Section(header: Text(provider).interFont(Constants.Typography.eyebrow)) {
                ForEach(rows, id: \.id) { @Sendable row in
                    row.content
                }
            }
            return (id: provider, content: section)
        }
        // Prepare row values on MainActor before SwiftUI requests them off-main.
        return List {
            ForEach(sections, id: \.id) { @Sendable section in
                section.content
            }
        }
    }

    private func modelButton(_ model: ModelInfo, isSelected: Bool) -> some View {
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
                if isSelected {
                    selectionIndicator
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
    }

    private var selectionIndicator: some View {
        Image(.check)
            .resizable()
            .scaledToFit()
            .frame(width: selectionIconSide, height: selectionIconSide)
            .foregroundStyle(Theme.primary(for: colorScheme))
            .accessibilityHidden(true)
    }
}
