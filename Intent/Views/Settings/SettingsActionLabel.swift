import SwiftUI

struct SettingsActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: SettingsStyle.rowSpacing) {
            Image(systemName: systemImage)
                .frame(width: SettingsStyle.iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, SettingsStyle.contentMargin)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
        .frame(minHeight: SettingsStyle.rowHeight)
        .contentShape(.rect)
    }
}
