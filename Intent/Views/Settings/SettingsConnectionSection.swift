import SwiftUI

struct SettingsConnectionSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .callout) private var iconSize = SettingsStyle.iconWidth
    let machineName: String?
    let onDisconnect: () -> Void

    var body: some View {
        SettingsSection(title: "Connection") {
            VStack(spacing: 0) {
                if let machineName {
                    machineRow(machineName)
                    Divider()
                }
                Button(action: onDisconnect) {
                    SettingsActionLabel(title: "Disconnect", image: .logout)
                        .foregroundStyle(Theme.destructive(for: colorScheme))
                }
            }
            .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
        }
    }

    private func machineRow(_ name: String) -> some View {
        HStack(spacing: SettingsStyle.rowSpacing) {
            Image(.connectionLaptop)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(name)
                .interFont(Constants.Typography.bodySEmphasized)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.connection.name")
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, SettingsStyle.contentMargin)
        .padding(.vertical, SettingsStyle.rowVerticalPadding)
        .frame(minHeight: SettingsStyle.rowHeight)
    }
}
