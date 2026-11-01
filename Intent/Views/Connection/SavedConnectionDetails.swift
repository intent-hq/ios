import SwiftUI

/// Secondary metadata reached through the card's existing context-menu affordance.
/// Never renders the saved API token or certificate fingerprint.
struct SavedConnectionDetails: View {
    @ScaledMetric(relativeTo: .subheadline) private var connectionIconSize: CGFloat = 15
    @Environment(\.colorScheme) private var colorScheme
    let connection: StoredConnection

    var body: some View {
        ConnectionSheet(initialHeight: Constants.Connections.initialSheetHeight) {
            VStack(alignment: .leading, spacing: Constants.ConnectionSheet.inset) {
                ConnectionSheetText("Connection Details", style: Constants.Typography.heading2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("saved-connection.details-title")
                Text(connection.displayName)
                    .interFont(Constants.Typography.bodySEmphasized)
                Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                    .interFont(Constants.Typography.bodyS)
                    .textSelection(.enabled)
                if let tcAddress = connection.server.tcAddress {
                    VStack(alignment: .leading, spacing: Constants.Connections.infoSpacing) {
                        Label { Text("Tailcat").interFont(Constants.Typography.bodyXS) } icon: {
                            Image(.connection).resizable().scaledToFit()
                                .frame(width: connectionIconSize, height: connectionIconSize)
                        }
                        Text(tcAddress)
                            .interFont(Constants.Typography.bodyXS)
                            .textSelection(.enabled)
                    }
                }
                if let lastConnected = connection.lastConnectedAt {
                    Text("Last connected \(lastConnected.formatted(.relative(presentation: .named)))")
                        .interFont(Constants.Typography.bodyXS)
                }
            }
            .foregroundStyle(Constants.ConnectionSheet.defaultForeground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
