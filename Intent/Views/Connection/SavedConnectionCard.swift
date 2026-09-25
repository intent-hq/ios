import SwiftUI

/// Data-only card label; selection and management remain owned by ConnectionsView.
struct SavedConnectionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let address: String
    let isCurrentWindow: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Constants.ConnectionSheet.inset) {
            // Saved records have no device-kind metadata. The exported server
            // glyph represents a daemon, not an inferred physical machine type.
            Image(.connectionServer)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Constants.Connections.cardTextSpacing) {
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
    }

    private var information: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Constants.Connections.infoSpacing) {
                if isCurrentWindow {
                    connectedStatus
                    Rectangle()
                        .fill(Constants.Connections.divider(for: colorScheme))
                        .frame(width: Constants.Connections.dividerWidth, height: Constants.Connections.dividerHeight)
                        .accessibilityHidden(true)
                }
                addressText
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: Constants.Connections.infoSpacing) {
                if isCurrentWindow { connectedStatus }
                addressText
            }
        }
    }

    private var addressText: some View {
        ConnectionSheetText(
            "\(address)", style: Constants.Typography.subtextXXS, tracking: Constants.Connections.infoTracking
        )
            .foregroundStyle(Constants.Connections.mutedForeground(for: colorScheme))
    }

    private var connectedStatus: some View {
        HStack(spacing: Constants.Connections.connectedSpacing) {
            Circle()
                .frame(width: Constants.Connections.statusDotSize, height: Constants.Connections.statusDotSize)
                .accessibilityHidden(true)
            ConnectionSheetText(
                "Connected", style: Constants.Typography.subtextXXS, tracking: Constants.Connections.infoTracking
            )
        }
        .foregroundStyle(Constants.Connections.connectedForeground(for: colorScheme))
    }
}