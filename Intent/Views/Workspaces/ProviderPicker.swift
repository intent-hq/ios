import SwiftUI

struct ProviderPicker: View {
    let providers: [ProviderInfo]
    let selectedProvider: ProviderInfo?
    var usesFormStyle = false
    let onSelect: (ProviderInfo) -> Void

    var body: some View {
        Group {
            if usesFormStyle {
                Menu {
                    picker.pickerStyle(.inline)
                } label: {
                    CreateWorkspaceChoiceLabel(title: selectedProvider?.displayName ?? String(localized: "None"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Provider")
                .accessibilityValue(selectedProvider?.displayName ?? String(localized: "None"))
                .accessibilityIdentifier("creation.providerPicker")
            } else {
                picker.pickerStyle(.menu)
            }
        }
    }

    private var picker: some View {
        Picker(selection: selection) {
            ForEach(providers) { provider in
                Text(Self.optionLabel(for: provider))
                    .interFont(Constants.Typography.bodyS)
                    .tag(provider.id)
            }
        } label: {
            Text("Provider").interFont(Constants.Typography.bodyS)
        }
        .accessibilityIdentifier("creation.providerPicker")
    }

    var selection: Binding<String> {
        Binding(
            get: { selectedProvider?.id ?? "" },
            set: { id in
                if let provider = providers.first(where: { $0.id == id }) {
                    onSelect(provider)
                }
            }
        )
    }

    static func optionLabel(for provider: ProviderInfo) -> String {
        provider.authenticated == false
            ? "\(provider.displayName) (not signed in)"
            : provider.displayName
    }
}
