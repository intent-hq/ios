import SwiftUI

/// Finalizes a successful pairing over the just-established connection: names the
/// connection after the daemon hostname (best-effort via `host.status`, preferring
/// the user-facing `prettyHostname` over the raw `hostname`, falling back to
/// host:port), saves it (upsert), and marks it active.
enum ConnectionPairing {
    enum PersistenceError: LocalizedError {
        /// The existing saved-connections data could not be read, so the new
        /// pairing was not written over it (intent-hq/ios#265).
        case registryUndecodable
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed:
                String(localized: "Could not save this connection. Please try again.")
            case .registryUndecodable:
                String(
                    localized:
                        "Could not save this connection: the existing saved connections could not be read. They were left untouched."
                )
            }
        }
    }

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

    /// `connection` is the session connection the pairing was established
    /// over, so a pinned session names and refreshes its own backend.
    @discardableResult
    static func finalize(
        server: PairedServer,
        token: String,
        connection: any SessionConnectionManaging,
        persistence: PersistenceManager = .shared
    ) async throws -> StoredConnection {
        var displayName: String?
        if let result = try? await connection.request("host.status") {
            displayName = Self.displayName(fromHostStatus: result)
        }
        let outcome = persistence.upsertConnectionWithOutcome(
            StoredConnection(
                server: server,
                token: token,
                displayName: displayName,
                lastConnectedAt: Date()
            )
        )
        guard !outcome.registryUndecodable else { throw PersistenceError.registryUndecodable }
        guard outcome.persisted else { throw PersistenceError.saveFailed }
        let stored = outcome.connection
        guard persistence.setActiveConnection(id: stored.id) else { throw PersistenceError.saveFailed }
        // Re-trigger the post-connect route refresh now that the record exists:
        // the refresh fired by connect() may have run before the upsert above
        // and found no stored record to persist the daemon-reported IPs into.
        Task {
            await connection.refreshHostRoutes()
            persistence.publishPendingBackends()
        }
        return stored
    }
}

/// Saved daemon connections. Pairing stays on the main Connect screen.
struct ConnectionsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    // False on iPhone, so the Open in New Window action never appears there.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @State private var connections: [StoredConnection] = []
    @State private var connectionShowingDetails: StoredConnection?
    @State private var connectionPendingDelete: StoredConnection?
    @State private var showDeleteError = false

    var body: some View {
        ConnectionSheet(
            initialHeight: Constants.Connections.initialSheetHeight,
            backgroundColor: Constants.Connections.background(for: colorScheme),
            closeForeground: Constants.Connections.foreground(for: colorScheme)
        ) {
            VStack(spacing: Constants.Connections.headingToCardsSpacing) {
                ConnectionSheetText(
                    "Saved Connections", style: Constants.Typography.heading2, tracking: Constants.Connections.headingTracking
                )
                .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("saved-connections.title")
                connectionsList
            }
        }
        .sheet(item: $connectionShowingDetails) { connection in
            SavedConnectionDetails(connection: connection)
        }
        .alert(
            "Delete Connection?",
            isPresented: Binding(
                get: { connectionPendingDelete != nil },
                set: { if !$0 { connectionPendingDelete = nil } }
            ),
            presenting: connectionPendingDelete
        ) { connection in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(connection) }
        } message: { connection in
            Text(connection.id == windowConnectionId
                ? "This is the current connection. Deleting it will disconnect you."
                : "This removes the saved connection. You'll need to pair again to reconnect.")
        }
        .alert("Couldn’t Delete Connection", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The saved connection could not be removed. Please try again.")
        }
        .onAppear {
            // Pull in registry changes synced from other devices while
            // the sheet was closed, then show the merged list.
            coordinator.refreshSyncedBackends()
            reload()
        }
    }

    private var connectionsList: some View {
        VStack(spacing: Constants.Connections.cardSpacing) {
            if connections.isEmpty {
                Text("No saved connections. Pair from the Connect screen to save a connection.")
                    .font(Constants.Typography.bodyS.font)
                    // No empty-state design reference: preserve its existing semantic light color.
                    .foregroundStyle(colorScheme == .dark
                        ? Constants.Pairing.mutedForeground(for: colorScheme) : Theme.mutedForeground(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("saved-connections.empty")
            } else {
                ForEach(connections) { connectionRow($0) }
            }
        }
    }

    /// The connection this window's backend is bound to (window model v2:
    /// "connected" badges and delete warnings are scoped to this window, not
    /// a global active pointer). Nil in an unbound pairing window.
    private var windowConnectionId: UUID? {
        coordinator.backendID?.connectionID
    }

    private func connectionRow(_ connection: StoredConnection) -> some View {
        Button {
            if connection.id != windowConnectionId {
                coordinator.onSwitchConnection(id: connection.id)
            }
            dismiss()
        } label: {
            SavedConnectionCard(
                name: connection.displayName,
                address: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)",
                isCurrentWindow: connection.id == windowConnectionId
            )
        }
        .buttonStyle(ConnectionSheetButtonStyle())
        .accessibilityIdentifier("saved-connection.\(connection.id)")
        .accessibilityHint("Touch and hold for connection details and actions.")
        .contextMenu {
            Button("Connection Details", systemImage: "info.circle") { connectionShowingDetails = connection }
            if supportsMultipleWindows {
                openInNewWindowButton(connection)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { connectionPendingDelete = connection }
        }
        .accessibilityActions {
            Button("Connection Details") { connectionShowingDetails = connection }
            if supportsMultipleWindows {
                openInNewWindowButton(connection)
            }
            Button("Delete", role: .destructive) { connectionPendingDelete = connection }
        }
    }

    /// Opens a window pinned to `connection` (visionOS and iPad only —
    /// supportsMultipleWindows is false on iPhone, so callers gate on it).
    private func openInNewWindowButton(_ connection: StoredConnection) -> some View {
        Button {
            openWindow(value: BackendID(connection: connection))
            dismiss()
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
    }

    private func delete(_ connection: StoredConnection) {
        let wasBound = connection.id == windowConnectionId
        guard coordinator.onDeleteConnection(id: connection.id) else {
            showDeleteError = true
            return
        }
        reload()
        if wasBound { dismiss() }
    }

    private func reload() {
        connections = PersistenceManager.shared.loadConnections()
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }
}
