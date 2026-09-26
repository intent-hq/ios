import SwiftUI

struct ProviderPicker: View {
    let providers: [ProviderInfo]
    let selectedProvider: ProviderInfo?
    let onSelect: (ProviderInfo) -> Void

    var body: some View {
        Picker(selection: selection) {
            ForEach(providers) { provider in
                Text(Self.optionLabel(for: provider))
                    .interFont(Constants.Typography.bodyS)
                    .tag(provider.id)
            }
        } label: {
            Text("Provider").interFont(Constants.Typography.bodyS)
        }
        .pickerStyle(.menu)
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
