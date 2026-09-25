import SwiftUI

struct SettingsConnectionsSection: View {
    let connections: [StoredConnection]
    let windowConnectionID: UUID?
    let status: ConnectionState
    let mismatches: [HostCertMismatch]
    let onSelect: (UUID) -> Void

    var body: some View {
        SettingsSection(title: "CONNECTIONS") {
            VStack(spacing: SettingsStyle.connectionCardSpacing) {
                ForEach(connections) { connection in
                    let isCurrent = connection.id == windowConnectionID
                    Button { onSelect(connection.id) } label: {
                        SettingsConnectionCard(
                            name: connection.displayName,
                            address: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)",
                            status: isCurrent ? status : nil
                        )
                    }
                    .accessibilityIdentifier("settings.connection.\(connection.id)")
                    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
                    .accessibilityHint(isCurrent ? Text("Return to workspaces") : Text("Switch to this connection"))
                }
            }
            if connections.isEmpty {
                Text("No saved connections")
                    .font(.callout)
            }
            if !mismatches.isEmpty {
                CertMismatchListView(mismatches: mismatches)
            }
        }
    }
}
