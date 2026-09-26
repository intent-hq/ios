import SwiftUI

/// A presentation-only card, also usable for the saved-connections list.
/// A nil status represents a saved connection that is not this window's backend.
struct SettingsConnectionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var iconSize = SettingsStyle.iconWidth
    let name: String
    let address: String
    let status: ConnectionState?

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SettingsStyle.metadataSpacing))
            : AnyLayout(HStackLayout(spacing: SettingsStyle.rowSpacing))
        layout {
            // The laptop icon matches Figma for all saved connections.
            Image(.connectionLaptop)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SettingsStyle.textSpacing) {
                Text(name).interFont(Constants.Typography.bodySEmphasized)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SettingsStyle.metadataSpacing) {
                        if status != nil {
                            statusLabel
                            Text("|")
                                .interFont(Constants.Typography.subtextXXS)
                                .accessibilityHidden(true)
                        }
                        Text(address)
                            .interFont(Constants.Typography.subtextXXS)
                    }
                    VStack(alignment: .leading, spacing: SettingsStyle.textSpacing) {
                        if status != nil { statusLabel }
                        Text(address)
                            .interFont(Constants.Typography.subtextXXS)
                    }
                }
                .foregroundStyle(SettingsStyle.muted(for: colorScheme, contrast: contrast))
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(SettingsStyle.foreground(for: colorScheme))
        .padding(SettingsStyle.contentMargin)
        .frame(maxWidth: .infinity, minHeight: SettingsStyle.connectionHeight, alignment: .leading)
        .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: some View {
        HStack(spacing: SettingsStyle.textSpacing) {
            Circle()
                .fill(status == .connected ? SettingsStyle.connected : SettingsStyle.muted(for: colorScheme, contrast: contrast))
                .frame(width: SettingsStyle.statusDotSize, height: SettingsStyle.statusDotSize)
                .accessibilityHidden(true)
            statusText
                .interFont(Constants.Typography.subtextXXS)
        }
        .foregroundStyle(contrast == .increased ? SettingsStyle.foreground(for: colorScheme) : statusColor)
    }

    private var statusColor: Color {
        status == .connected ? SettingsStyle.connected : SettingsStyle.muted(for: colorScheme, contrast: contrast)
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case .connected: Text("Connected")
        case .connecting: Text("Connecting")
        case .reconnecting: Text("Reconnecting")
        case .disconnected: Text("Disconnected")
        case nil: EmptyView()
        }
    }
}
