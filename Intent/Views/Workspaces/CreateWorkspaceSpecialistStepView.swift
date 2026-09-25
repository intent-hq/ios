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
    let onBack: () -> Void
    let onCreate: () -> Void
    let onLoad: () async -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            CreateWorkspaceFormStyle.background(for: colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                CreateWorkspaceFormHeader(
                    isCreateDisabled: CreateWorkspaceView.isCreateDisabled(
                        isCreating: isCreating,
                        isLoadingProviders: isLoadingProviders,
                        providers: providers,
                        selectedProvider: selectedProvider
                    ),
                    isCreating: isCreating,
                    onBack: onBack,
                    onCreate: onCreate
                )
                if isLoadingSpecialists {
                    ProgressView {
                        Text("Loading...").interFont(Constants.Typography.bodyS)
                    }
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    optionsList
                        .disabled(isCreating)
                }
            }
            if isCreating {
                creatingOverlay
            }
        }
        .navigationTitle("Create Workspace")
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(isCreating)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .task { await onLoad() }
    }

    private var optionsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Create Workspace")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, CreateWorkspaceFormStyle.headingSpacing)
                messageSection
                CreateWorkspaceSourceCard(repositoryFullName: repositoryFullName, branch: branch, onEdit: onBack)
                    .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
                agentSection
                    .padding(.top, CreateWorkspaceFormStyle.sectionSpacing)
            }
            .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
            .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
            .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
            .padding(.bottom, CreateWorkspaceFormStyle.pagePadding)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Text("AGENT")
                .font(.caption)
                .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, CreateWorkspaceFormStyle.controlPadding - CreateWorkspaceFormStyle.rowSpacing)
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
            } else if !providers.isEmpty {
                adaptiveField("Provider") { providerPicker }
            }
            if !providers.isEmpty, !models.isEmpty {
                adaptiveField("Model") { modelPicker }
            }
        }
    }

    private var messageSection: some View {
        TextField("What should we work on?", text: $messageText, axis: .vertical)
            .lineLimit(CreateWorkspaceView.initialMessageLineCountRange)
            .font(.callout)
            .padding(CreateWorkspaceFormStyle.pagePadding)
            .frame(minHeight: CreateWorkspaceFormStyle.promptHeight, alignment: .topLeading)
            .background(CreateWorkspaceFormStyle.card(for: colorScheme), in: .rect(
                cornerRadius: CreateWorkspaceFormStyle.cornerRadius
            ))
            .accessibilityIdentifier("creation.prompt")
            .accessibilityHint("Optional. Add instructions for the first agent in this workspace.")
    }

    private var specialistPicker: some View {
        Menu {
            Picker("Specialist", selection: Binding(
                get: { selectedSpecialist?.id ?? "" },
                set: { id in selectedSpecialist = specialists.first { $0.id == id } }
            )) {
                ForEach(specialists) { specialist in
                    Text(specialist.name).interFont(Constants.Typography.bodyS).tag(specialist.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            CreateWorkspaceChoiceLabel(title: selectedSpecialist?.name ?? String(localized: "None"))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Specialist")
        .accessibilityValue(selectedSpecialist?.name ?? String(localized: "None"))
        .accessibilityIdentifier("creation.specialistPicker")
    }

    private var providerPicker: some View {
        ProviderPicker(
            providers: providers,
            selectedProvider: selectedProvider,
            usesFormStyle: true,
            onSelect: onSelectProvider
        )
    }

    private var modelPicker: some View {
        ModelPicker(
            models: models,
            selectedModel: $selectedModel,
            daemonDefaultLabel: SpecialistInfo.daemonDefaultLabel(
                for: selectedSpecialist,
                providerId: selectedProvider?.id
            ),
            usesFormStyle: true
        )
    }

    @ViewBuilder
    private func adaptiveField<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if CreateWorkspaceView.usesExpandedFormLayout(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text(label)
                    .font(.callout)
                    .accessibilityHidden(true)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text(label)
                    .font(.callout)
                    .frame(width: CreateWorkspaceFormStyle.fieldLabelWidth, alignment: .leading)
                    .accessibilityHidden(true)
                content()
            }
        }
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
