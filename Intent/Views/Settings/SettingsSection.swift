import SwiftUI

struct SettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionHeaderSpacing) {
            Text(title)
                .interFont(Constants.Typography.eyebrow)
                .foregroundStyle(SettingsStyle.sectionForeground(for: colorScheme, contrast: contrast))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
