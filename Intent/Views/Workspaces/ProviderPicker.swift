import SwiftUI

struct ProviderPicker: View {
    let providers: [ProviderInfo]
    let selectedProvider: ProviderInfo?
    let onSelect: (ProviderInfo) -> Void

    var body: some View {
        Picker("Provider", selection: selection) {
            ForEach(providers) { provider in
                Text(Self.optionLabel(for: provider))
                    .tag(provider.id)
            }
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
