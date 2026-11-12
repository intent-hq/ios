#if os(iOS)
import SwiftUI

struct SettingsLiveActivityRow: View {
    @ScaledMetric(relativeTo: .callout) private var iconSize = SettingsStyle.iconWidth
    @AppStorage(AgentLiveActivityController.enabledKey) private var isEnabled = true

    var body: some View {
        Toggle(isOn: $isEnabled) {
            HStack(spacing: SettingsStyle.rowSpacing) {
                Image(.notification)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
                Text("Live Activities")
                    .interFont(Constants.Typography.bodySEmphasized)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(SettingsStyle.accent)
        .font(.callout.weight(.medium))
        .padding(.horizontal, SettingsStyle.contentMargin)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
        .frame(minHeight: SettingsStyle.rowHeight)
        .accessibilityIdentifier("settings.liveActivities")
        .onChange(of: isEnabled) { _, enabled in
            AgentLiveActivityController.shared.setEnabled(enabled)
            PushRelayController.shared.preferencesChanged()
        }
    }
}
#endif
