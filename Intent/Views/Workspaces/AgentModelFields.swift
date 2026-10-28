import SwiftUI

struct AgentModelFields: View {
    let providers: [ProviderInfo]
    let isLoadingProviders: Bool
    let providerGuidance: String?
    let selectedProvider: ProviderInfo?
    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    let daemonDefaultLabel: String
    let reasoningLevels: [String]
    @Binding var selectedReasoningEffort: String?
    var isLoadingModels = false
    var modelGuidance: String?
    let onSelectProvider: (ProviderInfo) -> Void
    let onRetryProviders: () -> Void
    var onRetryModels: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            providerField
            if selectedProvider != nil, !providers.isEmpty, providerGuidance == nil {
                AgentOptionField("Model") {
                    ModelPicker(models: models, selectedModel: $selectedModel, daemonDefaultLabel: daemonDefaultLabel, usesFormStyle: true)
                        .disabled(isLoadingModels || isLoadingProviders)
                }
                if isLoadingModels {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let modelGuidance {
                    Text(modelGuidance).interFont(Constants.Typography.bodyXS)
                    if let onRetryModels {
                        Button("Retry", action: onRetryModels).buttonStyle(IntentButtonStyle(variant: .secondary))
                    }
                }
                AgentOptionField("Reasoning") { reasoningPicker }
                if reasoningLevels.isEmpty {
                    Text("Choose a model with reasoning options to override Auto.")
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                }
            }
        }
    }

    @ViewBuilder private var providerField: some View {
        if let providerGuidance {
            Text(providerGuidance).interFont(Constants.Typography.bodyS)
            Button("Retry", action: onRetryProviders).buttonStyle(IntentButtonStyle(variant: .secondary))
        } else if isLoadingProviders, providers.isEmpty {
            ProgressView { Text("Loading providers...").interFont(Constants.Typography.bodyS) }
        } else if providers.noneSelectable {
            Text("No providers are signed in").interFont(Constants.Typography.bodyXSEmphasized)
            Text("Set up a provider in the Intent desktop app, then come back and try again.")
                .interFont(Constants.Typography.bodyXS)
        } else if !providers.isEmpty {
            AgentOptionField("Provider") {
                ProviderPicker(providers: providers, selectedProvider: selectedProvider, usesFormStyle: true, onSelect: onSelectProvider)
            }
        }
    }

    private var reasoningPicker: some View {
        Menu {
            Picker("Reasoning", selection: $selectedReasoningEffort) {
                Text("Auto").tag(String?.none)
                ForEach(reasoningLevels, id: \.self) { level in Text(level).tag(Optional(level)) }
            }
            .pickerStyle(.inline)
        } label: {
            CreateWorkspaceChoiceLabel(title: selectedReasoningEffort ?? String(localized: "Auto"))
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled((reasoningLevels.isEmpty && selectedReasoningEffort == nil) || isLoadingProviders || isLoadingModels)
        .accessibilityLabel("Reasoning")
        .accessibilityValue(selectedReasoningEffort ?? String(localized: "Auto"))
        .accessibilityHint("Auto uses the host's defaults. Other options override reasoning for the selected model.")
        .accessibilityIdentifier("creation.reasoningPicker")
    }
}

struct AgentOptionField<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text(label).interFont(Constants.Typography.bodyS).accessibilityHidden(true)
                content().frame(maxWidth: .infinity, alignment: .leading)
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
}
