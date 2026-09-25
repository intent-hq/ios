import SwiftUI

/// Secondary metadata reached through the card's existing context-menu affordance.
/// Never renders the saved API token or certificate fingerprint.
struct SavedConnectionDetails: View {
    @Environment(\.colorScheme) private var colorScheme
    let connection: StoredConnection

    var body: some View {
        ConnectionSheet(initialHeight: Constants.Connections.initialSheetHeight) {
            VStack(alignment: .leading, spacing: Constants.ConnectionSheet.inset) {
                ConnectionSheetText("Connection Details", style: Constants.Typography.heading2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("saved-connection.details-title")
                Text(connection.displayName)
                    .font(Constants.Typography.bodySEmphasized.font)
                Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                    .font(Constants.Typography.bodyS.font)
                    .textSelection(.enabled)
                if let tcAddress = connection.server.tcAddress {
                    VStack(alignment: .leading, spacing: Constants.Connections.infoSpacing) {
                        Label("Tailcat", systemImage: "point.3.connected.trianglepath.dotted")
                        Text(tcAddress).textSelection(.enabled)
                    }
                    .font(Constants.Typography.bodyXS.font)
                }
                if let lastConnected = connection.lastConnectedAt {
                    Text("Last connected \(lastConnected.formatted(.relative(presentation: .named)))")
                        .font(Constants.Typography.bodyXS.font)
                }
            }
            .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}