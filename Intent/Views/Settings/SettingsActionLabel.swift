import SwiftUI

struct SettingsActionLabel: View {
    @ScaledMetric(relativeTo: .callout) private var iconSize = SettingsStyle.iconWidth
    let title: LocalizedStringKey
    let image: ImageResource

    var body: some View {
        HStack(spacing: SettingsStyle.rowSpacing) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(title)
                .interFont(Constants.Typography.bodySEmphasized)
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
