import SwiftUI

/// Finalizes a successful pairing over the just-established connection: names the
/// connection after the daemon hostname (best-effort via `host.status`, preferring
/// the user-facing `prettyHostname` over the raw `hostname`, falling back to
/// host:port), saves it (upsert), and marks it active.
enum ConnectionPairing {
    /// Picks the connection display name from a `host.status` result:
    /// `prettyHostname` (user-facing, e.g. "Clement's Mac Studio") when present
    /// and non-blank, else `hostname`, else nil (caller falls back to host:port).
    /// Values are trimmed so whitespace-only names never win. Older daemons
    /// don't report `prettyHostname`.
    static func displayName(fromHostStatus result: Any) -> String? {
        guard let status = result as? [String: Any] else { return nil }
        for key in ["prettyHostname", "hostname"] {
            if let raw = status[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    @discardableResult
    static func finalize(server: PairedServer, token: String) async -> StoredConnection {
        var displayName: String?
        if let result = try? await ConnectionManager.shared.request("host.status") {
            displayName = Self.displayName(fromHostStatus: result)
        }
        let stored = PersistenceManager.shared.upsertConnection(
            StoredConnection(
                server: server, token: token,
                displayName: displayName, lastConnectedAt: Date()))
        PersistenceManager.shared.setActiveConnection(id: stored.id)
        // Re-trigger the post-connect route refresh now that the record exists:
        // the refresh fired by connect() may have run before the upsert above
        // and found no stored record to persist the daemon-reported IPs into.
        Task { await ConnectionManager.shared.refreshHostRoutes() }
        return stored
    }
}

/// "Connect to…" sheet: switch between saved daemon connections, delete saved
/// ones, or pair a new daemon.
struct ConnectionsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var connections: [StoredConnection] = []
    @State private var activeConnectionId: UUID?
    @State private var showQRScanner = false
    @State private var showManualEntry = false
    @State private var connectionPendingDelete: StoredConnection?

    var body: some View {
        NavigationStack {
            List {
                if !connections.isEmpty {
                    Section("Saved Connections") {
                        ForEach(connections) { connection in
                            connectionRow(connection)
                        }
                    }
                }

                Section("Pair New") {
                    Button {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "camera.fill")
                    }
                    Button {
                        showManualEntry = true
                    } label: {
                        Label("Manual Connection", systemImage: "keyboard")
                    }
                }
            }
            .navigationTitle("Connect to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(onPaired: handlePaired)
            }
            .sheet(isPresented: $showManualEntry) {
                ManualTokenEntryView(onPaired: handlePaired)
            }
            .alert(
                "Delete Connection?",
                isPresented: Binding(
                    get: { connectionPendingDelete != nil },
                    set: { if !$0 { connectionPendingDelete = nil } }),
                presenting: connectionPendingDelete
            ) { connection in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { delete(connection) }
            } message: { connection in
                Text(connection.id == activeConnectionId
                    ? "This is the current connection. Deleting it will disconnect you."
                    : "This removes the saved connection. You'll need to pair again to reconnect.")
            }
            .onAppear {
                // Pull in registry changes synced from other devices while
                // the sheet was closed, then show the merged list.
                coordinator.refreshSyncedBackends()
                reload()
            }
        }
    }

    private func connectionRow(_ connection: StoredConnection) -> some View {
        Button {
            if connection.id != activeConnectionId {
                coordinator.onSwitchConnection(id: connection.id)
            }
            dismiss()
        } label: {
            HStack(spacing: Constants.Connections.rowSpacing) {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(Theme.primary(for: colorScheme))

                VStack(alignment: .leading, spacing: Constants.Connections.rowTextSpacing) {
                    Text(connection.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    if let tcAddress = connection.server.tcAddress {
                        Label(tcAddress, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                    if let lastConnected = connection.lastConnectedAt {
                        Text("Last connected \(lastConnected.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                }

                Spacer()

                if connection.id == activeConnectionId {
                    HStack(spacing: Constants.Connections.statusSpacing) {
                        Circle()
                            .fill(.green)
                            .frame(width: Constants.Connections.statusDotSize,
                                   height: Constants.Connections.statusDotSize)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Not role: .destructive — the row must stay until the deletion is confirmed.
            Button("Delete") { connectionPendingDelete = connection }
                .tint(.red)
        }
    }

    private func handlePaired(_ connection: StoredConnection) {
        dismiss()
        coordinator.onSwitchConnection(id: connection.id)
    }

    private func delete(_ connection: StoredConnection) {
        let wasActive = connection.id == activeConnectionId
        coordinator.onDeleteConnection(id: connection.id)
        reload()
        if wasActive { dismiss() }
    }

    private func reload() {
        connections = PersistenceManager.shared.loadConnections()
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        activeConnectionId = PersistenceManager.shared.activeConnection()?.id
    }
}
