import SwiftUI

struct ModelPickerView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dismiss) var dismiss
    @State private var savingModelId: String?
    @State private var modelChangeError: String?

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
            .background(Constants.Pairing.background(for: colorScheme).ignoresSafeArea())
            .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
            .navigationTitle("Select Model")
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackground(Constants.Pairing.background(for: colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    IntentIconButton(icon: .close, label: "Cancel") { dismiss() }
                        .disabled(savingModelId != nil)
                }
                .intentToolbarSurface()
            }
            .task {
                await viewModel.refreshSelectableModels()
            }
            .alert(
                "Couldn't Change Model",
                isPresented: Binding(
                    get: { modelChangeError != nil },
                    set: { if !$0 { modelChangeError = nil } }
                ),
                presenting: modelChangeError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text(detail)
            }
        }
        .presentationBackground(Constants.Pairing.background(for: colorScheme))
        .interactiveDismissDisabled(savingModelId != nil)
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
            let header = Text(provider)
                .interFont(Constants.Typography.eyebrow)
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
            let section = Section(header: header) {
                ForEach(rows, id: \.id) { @Sendable row in
                    row.content
                }
            }
            .listRowBackground(Constants.Pairing.surface(for: colorScheme))
            return (id: provider, content: section)
        }
        // Prepare row values on MainActor before SwiftUI requests them off-main.
        return List {
            ForEach(sections, id: \.id) { @Sendable section in
                section.content
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func modelButton(_ model: ModelInfo, isSelected: Bool) -> some View {
        Button {
            selectModel(model.id)
        } label: {
            HStack {
                Text(model.name)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                Spacer()
                if savingModelId == model.id {
                    ProgressView()
                } else if isSelected {
                    selectionIndicator
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(savingModelId != nil)
        .accessibilityIdentifier("conversation.model.\(model.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectModel(_ modelId: String) {
        guard savingModelId == nil else { return }
        guard modelId != viewModel.currentModelId else {
            dismiss()
            return
        }
        savingModelId = modelId
        Task {
            defer { savingModelId = nil }
            do {
                try await viewModel.setModel(modelId)
                dismiss()
            } catch {
                modelChangeError = error.localizedDescription
            }
        }
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
