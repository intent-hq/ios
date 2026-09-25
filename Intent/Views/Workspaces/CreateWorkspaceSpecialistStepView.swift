import SwiftUI

struct CreateWorkspaceSpecialistStepView: View {
    let repositoryFullName: String
    let branch: String
    let specialists: [SpecialistInfo]
    let isLoadingSpecialists: Bool
    @Binding var selectedSpecialist: SpecialistInfo?
    let providers: [ProviderInfo]
    let isLoadingProviders: Bool
    let providerGuidance: String?
    @Binding var selectedProvider: ProviderInfo?
    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    @Binding var messageText: String
    let isCreating: Bool
    let errorMessage: String?
    @Binding var showError: Bool
    let colorScheme: ColorScheme
    let onSelectProvider: (ProviderInfo) -> Void
    let onRetryProviders: () -> Void
    let onCreate: () -> Void
    let onLoad: () async -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            if isLoadingSpecialists {
                ProgressView {
                    Text("Loading...").interFont(Constants.Typography.bodyS)
                }
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: onCreate)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .disabled(CreateWorkspaceView.isCreateDisabled(
                        isCreating: isCreating,
                        isLoadingProviders: isLoadingProviders,
                        providers: providers,
                        selectedProvider: selectedProvider
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
            sourceSection
            agentSection
            messageSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var sourceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Constants.CreateWorkspace.branchBadgeVerticalPadding) {
                ForEach(CreateWorkspaceView.creationContextRows(
                    repositoryFullName: repositoryFullName,
                    branch: branch
                )) { row in
                    contextRow(row)
                }
            }
        } header: {
            Text("Source").interFont(Constants.Typography.eyebrow)
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        Section {
            adaptiveField("Specialist") { specialistPicker }
            if let providerGuidance {
                Text(providerGuidance)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Button("Retry", action: onRetryProviders)
                    .interFont(Constants.Typography.bodyS)
            } else if isLoadingProviders, providers.isEmpty {
                ProgressView {
                    Text("Loading providers...").interFont(Constants.Typography.bodyS)
                }
            } else if providers.noneSelectable {
                noProvidersSignedInPlaceholder
                    .listRowBackground(Theme.card(for: colorScheme))
            } else if !providers.isEmpty {
                adaptiveField("Provider") { providerPicker }
            }
            if !providers.isEmpty, !models.isEmpty {
                adaptiveField("Model") { modelPicker }
            }
        } header: {
            Text("Agent").interFont(Constants.Typography.eyebrow)
        }
    }

    private var messageSection: some View {
        Section {
            TextField("What should the first agent work on?", text: $messageText, axis: .vertical)
                .lineLimit(CreateWorkspaceView.initialMessageLineCountRange)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .listRowBackground(Theme.card(for: colorScheme))
        } header: {
            Text("Message")
                .interFont(Constants.Typography.eyebrow)
        } footer: {
            Text("Optional. Add instructions for the first agent in this workspace.")
                .interFont(Constants.Typography.subtextXXS)
        }
    }

    private var specialistPicker: some View {
        Picker("Specialist", selection: Binding(
            get: { selectedSpecialist?.id ?? "" },
            set: { id in selectedSpecialist = specialists.first { $0.id == id } }
        )) {
            ForEach(specialists) { specialist in
                Text(specialist.name).interFont(Constants.Typography.bodyS).tag(specialist.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .listRowBackground(Theme.card(for: colorScheme))
    }

    private var providerPicker: some View {
        ProviderPicker(
            providers: providers,
            selectedProvider: selectedProvider,
            onSelect: onSelectProvider
        )
        .labelsHidden()
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
        .labelsHidden()
        .listRowBackground(Theme.card(for: colorScheme))
    }

    @ViewBuilder
    private func adaptiveField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if CreateWorkspaceView.usesExpandedFormLayout(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: Constants.CreateWorkspace.branchBadgeVerticalPadding) {
                Text(label)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LabeledContent {
                content()
            } label: {
                Text(label).interFont(Constants.Typography.bodyS)
            }
        }
    }

    @ViewBuilder
    private func contextRow(_ row: CreateWorkspaceView.CreationContextRow) -> some View {
        Group {
            if CreateWorkspaceView.usesExpandedFormLayout(for: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: Constants.CreateWorkspace.branchBadgeVerticalPadding) {
                    Text(row.label)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    Text(row.value)
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LabeledContent {
                    Text(row.value)
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(Constants.CreateWorkspace.contextValueLineLimit)
                        .truncationMode(.middle)
                } label: {
                    Text(row.label).interFont(Constants.Typography.bodyS)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: CreateWorkspaceView.creationContextAccessibilityDescription(row)))
    }

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

    private var creatingOverlay: some View {
        Group {
            Color.black.opacity(Constants.ModalPicker.loadingOverlayOpacity).ignoresSafeArea()
            VStack(spacing: Constants.ModalPicker.loadingOverlaySpacing) {
                ProgressView()
                Text("Cloning repository…")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .padding(Constants.ModalPicker.loadingOverlayPadding)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Constants.ModalPicker.loadingOverlayCornerRadius))
        }
    }
}

extension CreateWorkspaceView {
    struct InitialAgentInput {
        let specialist: SpecialistInfo?
        let provider: ProviderInfo?
        let model: ModelInfo?
        let message: String
    }

    static var initialMessageLineCountRange: ClosedRange<Int> {
        1...Constants.CreateWorkspace.messageLineCountRange.upperBound
    }

    static func creationContextAccessibilityDescription(_ row: CreationContextRow) -> String {
        "\(row.label): \(row.value.isEmpty ? "Not specified" : row.value)"
    }

    static func isCreateDisabled(
        isCreating: Bool,
        isLoadingProviders: Bool,
        providers: [ProviderInfo],
        selectedProvider: ProviderInfo?
    ) -> Bool {
        guard !isCreating, !isLoadingProviders, let selectedProvider else { return true }
        return !providers.contains { $0.id == selectedProvider.id && $0.isSelectable }
    }

    static func buildCreateWorkspaceParams(
        githubUrl: String,
        baseRef: String,
        idempotencyKey: String,
        initialAgent: InitialAgentInput
    ) -> [String: Any] {
        var params: [String: Any] = [
            "githubUrl": githubUrl,
            "baseRef": baseRef,
            "idempotencyKey": idempotencyKey
        ]
        let trimmedMessage = initialAgent.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = !trimmedMessage.isEmpty
        if initialAgent.specialist != nil || hasMessage || initialAgent.model != nil || initialAgent.provider != nil {
            var initialAgentParams: [String: Any] = [:]
            if let specialist = initialAgent.specialist { initialAgentParams["specialist"] = specialist.id }
            // Always send the enabled selection, including Auggie. The host's
            // default (or specialist default) may name a disabled provider.
            if let provider = initialAgent.provider {
                initialAgentParams["provider"] = provider.id
            }
            if let model = initialAgent.model { initialAgentParams["model"] = model.id }
            if hasMessage { initialAgentParams["prompt"] = trimmedMessage }
            params["initialAgent"] = initialAgentParams
        }
        return params
    }
}
