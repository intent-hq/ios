import SwiftUI

struct CreateWorkspaceSpecialistStepView: View {
    let repositoryFullName: String
    let branch: String?
    let specialists: [SpecialistInfo]
    let isLoadingSpecialists: Bool
    @Binding var selectedSpecialist: SpecialistInfo?
    let providers: [ProviderInfo]
    let isLoadingProviders: Bool
    let providerGuidance: String?
    @Binding var selectedProvider: ProviderInfo?
    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    let reasoningLevels: [String]
    @Binding var selectedReasoningEffort: String?
    @Binding var messageText: String
    let images: WorkspaceCreationImages
    let isCreating: Bool
    let allowsCreation: Bool
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
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .title) private var headingTracking = CreateWorkspaceFormStyle.headingTracking
    @ScaledMetric(relativeTo: .title) private var headingSize = Constants.Typography.heading2.size

    var body: some View {
        ZStack {
            CreateWorkspaceFormStyle.background(for: colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                CreateWorkspaceFormHeader(isCreating: isCreating, onBack: onBack)
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
            .safeAreaInset(edge: .bottom, spacing: 0) { createControls }
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

    private var createControls: some View {
        HStack {
            Spacer()
            CreateWorkspaceSubmitButton(
                isDisabled: CreateWorkspaceView.isCreateDisabled(
                    isCreating: isCreating,
                    isLoadingProviders: isLoadingProviders,
                    providers: providers,
                    selectedProvider: selectedProvider,
                    allowsCreation: allowsCreation,
                    isImportingImages: images.isImporting
                ),
                onCreate: onCreate
            )
        }
        .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
        .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
        .padding(.bottom, CreateWorkspaceFormStyle.pagePadding)
        .background(CreateWorkspaceFormStyle.background(for: colorScheme))
    }

    private var optionsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeading
                    .padding(.bottom, CreateWorkspaceFormStyle.headingSpacing)
                CreateWorkspacePrompt(text: $messageText, attachments: images)
                CreateWorkspaceSourceCard(repositoryFullName: repositoryFullName, branch: branch, onEdit: onBack)
                    .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
                agentSection
                    .padding(.top, CreateWorkspaceFormStyle.agentSectionSpacing)
            }
            .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
            .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
            .padding(.top, CreateWorkspaceFormStyle.pagePadding)
            .padding(.bottom, CreateWorkspaceFormStyle.pagePadding)
        }
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private var pageHeading: some View {
        let style = Constants.Typography.heading2
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, headingSize, nil)
        return WorkspaceTextTrimLayout(capHeight: CTFontGetCapHeight(font)) {
            Text("Create Workspace")
                .interFont(style)
                .tracking(headingTracking)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var agentHeading: some View {
        Text("AGENT")
            .interFont(Constants.Typography.eyebrow)
            .tracking(CreateWorkspaceFormStyle.agentHeadingTracking)
            .dynamicTypeSize(.large...)
            .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            agentHeading
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
            adaptiveField("Reasoning") { reasoningPicker }
            if reasoningLevels.isEmpty {
                Text("Choose a model with reasoning options to override Auto.")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
            }
        }
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

    private var reasoningPicker: some View {
        Menu {
            Picker("Reasoning", selection: $selectedReasoningEffort) {
                Text("Auto").tag(String?.none)
                ForEach(reasoningLevels, id: \.self) { level in
                    Text(level).tag(Optional(level))
                }
            }
            .pickerStyle(.inline)
        } label: {
            CreateWorkspaceChoiceLabel(title: selectedReasoningEffort ?? String(localized: "Auto"))
        }
        .buttonStyle(.plain)
        .disabled(reasoningLevels.isEmpty || isLoadingProviders)
        .accessibilityLabel("Reasoning")
        .accessibilityValue(selectedReasoningEffort ?? String(localized: "Auto"))
        .accessibilityHint("Auto uses the host's defaults. Other options override reasoning for the selected model.")
        .accessibilityIdentifier("creation.reasoningPicker")
    }

    @ViewBuilder
    private func adaptiveField<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if CreateWorkspaceView.usesExpandedFormLayout(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text(label)
                    .interFont(Constants.Typography.bodyS)
                    .accessibilityHidden(true)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text(label)
                    .interFont(Constants.Typography.bodyS)
                    .frame(width: CreateWorkspaceFormStyle.fieldLabelWidth, alignment: .leading)
                    .accessibilityHidden(true)
                content()
            }
        }
    }

    private var noProvidersSignedInPlaceholder: some View {
        VStack(alignment: .leading, spacing: Constants.ModalPicker.placeholderSpacing) {
            Text("No providers are signed in")
                .interFont(Constants.Typography.bodyXSEmphasized)
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
    static let createRequestTimeout: TimeInterval = 120

    /// A failed cold load settles; an uncached load still in flight gates creation.
    static func showsOptionsLoading(
        storeIsLoading: Bool, storeHasLoaded: Bool, settled: Bool
    ) -> Bool {
        storeIsLoading || (!storeHasLoaded && !settled)
    }

    // swiftlint:disable discouraged_optional_boolean
    /// A missing provider needs no load; a failed catalog falls back to the daemon default.
    static func showsModelCatalogLoading(catalogCached: Bool?, settled: Bool) -> Bool {
        catalogCached == false && !settled
    }
    // swiftlint:enable discouraged_optional_boolean

    static func usesExpandedFormLayout(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    struct InitialAgentInput {
        let specialist: SpecialistInfo?
        let provider: ProviderInfo?
        let model: ModelInfo?
        let message: String
        var reasoningEffort: String?
        var imageBlocks: [[String: Any]] = []
    }

    static var initialMessageLineCountRange: ClosedRange<Int> {
        1...Constants.CreateWorkspace.messageLineCountRange.upperBound
    }

    static func isCreateDisabled(
        isCreating: Bool,
        isLoadingProviders: Bool,
        providers: [ProviderInfo],
        selectedProvider: ProviderInfo?,
        allowsCreation: Bool = true,
        isImportingImages: Bool = false
    ) -> Bool {
        guard allowsCreation, !isCreating, !isLoadingProviders, !isImportingImages,
              let selectedProvider else { return true }
        return !providers.contains { $0.id == selectedProvider.id && $0.isSelectable }
    }

    static func buildCreateWorkspaceParams(
        githubUrl: String,
        baseRef: String,
        idempotencyKey: String,
        initialAgent: InitialAgentInput
    ) -> [String: Any] {
        buildCreateWorkspaceParams(
            source: .github(url: githubUrl, baseRef: baseRef),
            idempotencyKey: idempotencyKey,
            initialAgent: initialAgent
        )
    }

    static func buildCreateWorkspaceParams(
        source: WorkspaceRepositorySource,
        idempotencyKey: String,
        initialAgent: InitialAgentInput
    ) -> [String: Any] {
        var params = source.parameters
        params["idempotencyKey"] = idempotencyKey
        let trimmedMessage = initialAgent.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = !trimmedMessage.isEmpty
        if initialAgent.specialist != nil || hasMessage || initialAgent.model != nil
            || initialAgent.provider != nil || !initialAgent.imageBlocks.isEmpty {
            var initialAgentParams: [String: Any] = [:]
            if let specialist = initialAgent.specialist { initialAgentParams["specialist"] = specialist.id }
            // Always send the enabled selection, including Auggie. The host's
            // default (or specialist default) may name a disabled provider.
            if let provider = initialAgent.provider {
                initialAgentParams["provider"] = provider.id
            }
            if let model = initialAgent.model { initialAgentParams["model"] = model.id }
            if let effort = initialAgent.reasoningEffort { initialAgentParams["reasoningEffort"] = effort }
            if hasMessage { initialAgentParams["prompt"] = trimmedMessage }
            if !initialAgent.imageBlocks.isEmpty { initialAgentParams["imageBlocks"] = initialAgent.imageBlocks }
            params["initialAgent"] = initialAgentParams
        }
        return params
    }
}
