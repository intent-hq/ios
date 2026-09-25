import SwiftUI

struct SettingsAppearanceSelector: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: SettingsStyle.trackInset))
            : AnyLayout(HStackLayout(spacing: SettingsStyle.trackInset))
        layout {
            option("Light", value: "light")
            option("Dark", value: "dark")
            option("System", value: "system")
        }
        .padding(SettingsStyle.trackInset)
        .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }

    private func option(_ title: LocalizedStringKey, value: String) -> some View {
        let selected = selection == value
        let selectedForeground = colorScheme == .dark ? SettingsStyle.lightForeground : .white
        let selectedBackground = colorScheme == .dark ? SettingsStyle.lightSurface : SettingsStyle.charcoal
        return Button { selection = value } label: {
            Text(title)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsStyle.trackInset)
                .padding(.vertical, SettingsStyle.trackInset)
                .frame(maxWidth: .infinity, minHeight: SettingsStyle.segmentHeight)
                .foregroundStyle(selected ? selectedForeground : SettingsStyle.foreground(for: colorScheme))
                .background(selected ? selectedBackground : .clear, in: .rect(cornerRadius: SettingsStyle.segmentRadius))
                .contentShape(.rect(cornerRadius: SettingsStyle.segmentRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("settings.appearance.\(value)")
    }
}
