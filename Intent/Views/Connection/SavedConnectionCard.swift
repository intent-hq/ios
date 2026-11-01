import SwiftUI

/// Shared card label; selection and management remain owned by each presenting screen.
struct SavedConnectionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var iconSize = Constants.ConnectionSheet.glyphSize
    let name: String
    let address: String
    let status: ConnectionState?
    let textSpacing: CGFloat

    init(name: String, address: String, isCurrentWindow: Bool) {
        self.init(name: name, address: address, status: isCurrentWindow ? .connected : nil)
    }

    init(
        name: String,
        address: String,
        status: ConnectionState?,
        textSpacing: CGFloat = Constants.Connections.cardTextSpacing
    ) {
        self.name = name
        self.address = address
        self.status = status
        self.textSpacing = textSpacing
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Constants.Connections.infoSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Constants.ConnectionSheet.inset))
        layout {
            // The laptop icon matches Figma for all saved connections.
            Image(.connectionLaptop)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: textSpacing) {
                ConnectionSheetText(
                    "\(name)", style: Constants.Typography.bodySEmphasized, tracking: Constants.Connections.nameTracking
                )
                information
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
        .padding(Constants.ConnectionSheet.inset)
        .frame(maxWidth: .infinity, minHeight: Constants.Connections.cardMinimumHeight, alignment: .leading)
        .background(
            Constants.Connections.surface(for: colorScheme),
            in: .rect(cornerRadius: Constants.ConnectionSheet.fieldCornerRadius)
        )
        .contentShape(.rect(cornerRadius: Constants.ConnectionSheet.fieldCornerRadius))
        .accessibilityElement(children: .combine)
    }

    private var information: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Constants.Connections.infoSpacing) {
                if status != nil {
                    statusLabel
                    Rectangle()
                        .fill(Constants.Connections.divider(for: colorScheme))
                        .frame(width: Constants.Connections.dividerWidth, height: Constants.Connections.dividerHeight)
                        .accessibilityHidden(true)
                }
                addressText
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: Constants.Connections.infoSpacing) {
                if status != nil { statusLabel }
                addressText
            }
        }
    }

    private var addressText: some View {
        ConnectionSheetText(
            "\(address)", style: Constants.Typography.subtextXXS, tracking: Constants.Connections.infoTracking
        )
            .foregroundStyle(mutedForeground)
    }

    private var statusLabel: some View {
        HStack(spacing: Constants.Connections.connectedSpacing) {
            Circle()
                .fill(statusForeground)
                .frame(width: Constants.Connections.statusDotSize, height: Constants.Connections.statusDotSize)
                .accessibilityHidden(true)
            if let statusTitle {
                ConnectionSheetText(
                    statusTitle, style: Constants.Typography.subtextXXS, tracking: Constants.Connections.infoTracking
                )
            }
        }
        .foregroundStyle(contrast == .increased ? Constants.Connections.foreground(for: colorScheme) : statusForeground)
    }

    private var mutedForeground: Color {
        contrast == .increased
            ? Constants.Connections.foreground(for: colorScheme)
            : Constants.Connections.mutedForeground(for: colorScheme)
    }

    private var statusForeground: Color {
        status == .connected
            ? Constants.Connections.connectedForeground(for: colorScheme)
            : Constants.Connections.statusMutedForeground(for: colorScheme)
    }

    private var statusTitle: LocalizedStringKey? {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        case nil: nil
        }
    }
}
