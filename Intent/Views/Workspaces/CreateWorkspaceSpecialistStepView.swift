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
    let selectedProvider: ProviderInfo?
    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    let reasoningLevels: [String]
    @Binding var selectedReasoningEffort: String?
    @Binding var messageText: String
    let images: WorkspaceCreationImages
    let isCreating: Bool
    var videoSubmission: WorkspaceCreationVideoSubmission?
    let allowsCreation: Bool
    let errorMessage: String?
    @Binding var showError: Bool
    let colorScheme: ColorScheme
    let onSelectProvider: (ProviderInfo) -> Void
    let onRetryProviders: () -> Void
    let onBack: () -> Void
    let onCreate: () -> Void
    let onLoad: () async -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .title) private var headingTracking = CreateWorkspaceFormStyle.headingTracking
    @ScaledMetric(relativeTo: .title) private var headingSize = Constants.Typography.heading2.size
    @State private var createControlsHeight: CGFloat = 0
    @State private var promptFocus = WorkspacePromptFocus()

    var body: some View {
        ZStack {
            CreateWorkspaceFormStyle.background(for: colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                if isLoadingSpecialists {
                    ProgressView {
                        Text("Loading...").interFont(Constants.Typography.bodyS)
                    }
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    optionsList
                        .disabled(isCreating || videoSubmission != nil)
                        .allowsHitTesting(!promptFocus.isDismissing)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                createControls
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { createControlsHeight = $0 }
            }
        }
        .navigationTitle("Create Workspace")
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(isCreating || promptFocus.isDismissing)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .task { await onLoad() }
        .onDisappear { promptFocus.cancelDismissal() }
    }

    private var createControls: some View {
        HStack {
            CreateWorkspaceNavigationButton(
                control: videoSubmission == nil ? .back : .close, identifier: "creation.back", onAction: onBack
            )
                .disabled(isCreating || promptFocus.isDismissing)
            Spacer()
            CreateWorkspaceSubmitButton(
                isCreating: isCreating,
                isDisabled: videoSubmission != nil
                    ? (isCreating || promptFocus.isDismissing || !allowsCreation)
                    : CreateWorkspaceView.isCreateDisabled(
                    isCreating: isCreating || promptFocus.isDismissing,
                    isLoadingProviders: isLoadingProviders,
                    providers: providers,
                    selectedProvider: selectedProvider,
                    allowsCreation: allowsCreation,
                    isImportingImages: images.isImporting
                ),
                title: submitTitle
            ) {
                promptFocus.dismissKeyboard { onCreate() }
            }
            .requiresLiveConnection()
        }
        .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
        .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
        .padding(.bottom, CreateWorkspaceFormStyle.pagePadding)
    }

    private var submitTitle: LocalizedStringKey {
        guard let videoSubmission else { return "Create" }
        return videoSubmission.needsStatusCheck ? "Check status" : "Retry"
    }

    private var optionsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeading
                    .padding(.top, CreateWorkspaceFormStyle.headingTopPadding)
                    .padding(.bottom, CreateWorkspaceFormStyle.headingSpacing)
                CreateWorkspacePrompt(text: $messageText, attachments: images, focus: promptFocus)
                if let videoSubmission {
                    if videoSubmission.isUploading {
                        ProgressView(value: videoSubmission.uploadProgress) { Text("Uploading videos…") }
                            .accessibilityIdentifier("creation.videoUploadProgress")
                    } else if !isCreating {
                        Text("Your prompt and attachments are saved. Continue this submission before starting another workspace.")
                            .interFont(Constants.Typography.bodyXS)
                    }
                }
                CreateWorkspaceSourceCard(repositoryFullName: repositoryFullName, branch: branch, onEdit: onBack)
                    .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
                agentSection
                    .padding(.top, CreateWorkspaceFormStyle.agentSectionSpacing)
            }
            .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
            .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
            .padding(.top, CreateWorkspaceFormStyle.pagePadding)
            .padding(.bottom, CreateWorkspaceFormStyle.pagePadding + createControlsHeight)
        }
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .accessibilityIdentifier("creation.form")
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
            AgentOptionField("Specialist") { specialistPicker }
            AgentModelFields(
                providers: providers,
                isLoadingProviders: isLoadingProviders,
                providerGuidance: providerGuidance,
                selectedProvider: selectedProvider,
                models: models,
                selectedModel: $selectedModel,
                daemonDefaultLabel: SpecialistInfo.daemonDefaultLabel(for: selectedSpecialist, providerId: selectedProvider?.id),
                reasoningLevels: reasoningLevels,
                selectedReasoningEffort: $selectedReasoningEffort,
                onSelectProvider: onSelectProvider,
                onRetryProviders: onRetryProviders
            )
        }
    }

    private var specialistPicker: some View {
        Menu {
            Picker("Specialist", selection: Binding(
                get: { selectedSpecialist?.id ?? "" },
                set: { id in selectedSpecialist = specialists.first { $0.id == id } }
            )) {
                Text("None").tag("")
                ForEach(specialists) { specialist in
                    Text(specialist.name).interFont(Constants.Typography.bodyS).tag(specialist.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            CreateWorkspaceChoiceLabel(title: selectedSpecialist?.name ?? String(localized: "None"))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Specialist")
        .accessibilityValue(selectedSpecialist?.name ?? String(localized: "None"))
        .accessibilityIdentifier("creation.specialistPicker")
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

    // A missing provider needs no load; a failed catalog falls back to the daemon default.
    // Nil means no provider is selected; false means its catalog has not loaded yet.
    // swiftlint:disable:next discouraged_optional_boolean
    static func showsModelCatalogLoading(catalogCached: Bool?, settled: Bool) -> Bool {
        catalogCached == false && !settled
    }

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
