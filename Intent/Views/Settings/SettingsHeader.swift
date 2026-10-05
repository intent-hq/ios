import SwiftUI

struct SettingsHeader: View {
    @ScaledMetric private var iconSize = SettingsStyle.iconWidth
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.headerGap) {
            Button(action: onClose) {
                Label {
                    Text("Close Settings")
                } icon: {
                    Image(.connectionClose)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                }
                    .labelStyle(.iconOnly)
                    .frame(width: Constants.Accessibility.minimumTapTarget, height: Constants.Accessibility.minimumTapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityIdentifier("settings.close")
            Text("Settings")
                .interFont(Constants.Typography.heading2)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
