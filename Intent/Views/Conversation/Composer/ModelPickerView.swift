import SwiftUI

struct ModelPickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ConversationModelSelection

    init(viewModel: ConversationViewModel) {
        _selection = State(initialValue: ConversationModelSelection(viewModel: viewModel))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                fields.padding(CreateWorkspaceFormStyle.pagePadding)
            }
            .accessibilityIdentifier("conversation.model.form")
            .background(CreateWorkspaceFormStyle.background(for: colorScheme))
            .safeAreaInset(edge: .bottom) { formControls }
            .navigationTitle("Model Settings")
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackground(CreateWorkspaceFormStyle.background(for: colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task(id: selection.options.loadGeneration) { await selection.load() }
            .task(id: selection.catalogKey) { await selection.loadModels() }
            .onDisappear { selection.deactivate() }
            .alert("Couldn't Save Model Settings", isPresented: Binding(
                get: { selection.errorMessage != nil }, set: { if !$0 { selection.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(selection.errorMessage ?? "")
            }
        }
        .presentationBackground(CreateWorkspaceFormStyle.background(for: colorScheme))
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(selection.isSaving)
    }

    private var fields: some View {
        AgentModelFields(
            providers: selection.providers,
            isLoadingProviders: selection.isLoading || selection.providerOptions.isLoading,
            providerGuidance: selection.providerGuidance,
            selectedProvider: selection.provider,
            models: selection.models,
            selectedModel: Binding(get: { selection.model }, set: { selection.selectModel($0) }),
            daemonDefaultLabel: String(localized: "Provider default"),
            reasoningLevels: selection.reasoningLevels,
            selectedReasoningEffort: $selection.reasoningEffort,
            isLoadingModels: selection.isLoadingModels,
            modelGuidance: selection.modelGuidance,
            onSelectProvider: selection.selectProvider,
            onRetryProviders: { Task { await selection.load() } },
            onRetryModels: { Task { await selection.loadModels() } }
        )
        .disabled(selection.isSaving)
    }

    private var formControls: some View {
        HStack {
            CreateWorkspaceNavigationButton(control: .close, identifier: "conversation.model.cancel") { dismiss() }
                .accessibilityLabel("Cancel")
                .disabled(selection.isSaving)
            Spacer()
            CreateWorkspaceSubmitButton(
                isCreating: selection.isSaving,
                isDisabled: !selection.canSave,
                title: "Save",
                progressTitle: "Saving model settings",
                icon: .check,
                identifier: "conversation.model.save"
            ) {
                Task { if await selection.save() { dismiss() } }
            }
            .requiresLiveConnection()
        }
        .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
        .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
        .padding(.bottom, CreateWorkspaceFormStyle.pagePadding)
        .background(CreateWorkspaceFormStyle.background(for: colorScheme))
    }
}
