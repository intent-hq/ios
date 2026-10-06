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
        let admissionID = connection.admission?.id
        let principal = try await connection.confirmedPrincipal()
        try Task.checkCancellation()
        let receipt = try connection.pairingAdmission(token: token, fingerprint: server.certFingerprint)
        guard receipt.id == admissionID else { throw ConnectionPrincipal.AdmissionError.personChanged }
        let personKey = principal.isOwner ? nil : try server.certFingerprint.map { try InvitedSyncKey.session(fingerprint: $0, principalId: principal.id) }
        let floor = personKey.flatMap { persistence.invitedJournal.floors[$0] } ?? 0
        var displayName: String?
        if let result = try? await connection.request("host.status") {
            displayName = Self.displayName(fromHostStatus: result)
        }
        try Task.checkCancellation()
        try connection.validatePairingAdmission(receipt)
        guard (personKey.flatMap { persistence.invitedJournal.floors[$0] } ?? 0) == floor else { throw ConnectionPrincipal.AdmissionError.personChanged }
        var candidate = StoredConnection(
                server: server,
                token: token,
                displayName: displayName,
                lastConnectedAt: Date()
            )
        candidate.principal = principal
        try persistence.prepareInvitedPairing(&candidate)
        try Task.checkCancellation()
        try connection.validatePairingAdmission(receipt)
        let outcome = persistence.upsertConnectionWithOutcome(candidate)
        guard !outcome.registryUndecodable else { throw PersistenceError.registryUndecodable }
        guard outcome.persisted else { throw PersistenceError.saveFailed }
        let stored = outcome.connection
        guard persistence.setActiveConnection(id: stored.id) else { throw PersistenceError.saveFailed }
        // Re-trigger the post-connect route refresh now that the record exists:
        // the refresh fired by connect() may have run before the upsert above
        // and found no stored record to persist the daemon-reported IPs into.
        Task {
            guard (try? connection.validatePairingAdmission(receipt)) != nil else { return }
            await connection.refreshHostRoutes()
            persistence.publishPendingBackends()
        }
        return stored
    }
}

/// Saved daemon connections and direct actions to pair another daemon.
struct ConnectionsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

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
                VStack(spacing: Constants.Connections.cardsToPairingSpacing) {
                    SavedConnectionsList { dismiss() }
                    ConnectionPairingActions(colorScheme: colorScheme, onPaired: handlePaired)
                }
            }
        }
    }

    private func handlePaired(_ connection: StoredConnection) {
        dismiss()
        coordinator.onPaired(connection)
    }
}

struct SavedConnectionsList: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    var showsEmptyState = true
    var showsHeading = false
    var onSelection: () -> Void = {}
    @State private var connections: [StoredConnection] = []
    @State private var connectionShowingDetails: StoredConnection?
    @State private var connectionPendingDelete: StoredConnection?
    @State private var showDeleteError = false
    @ScaledMetric private var menuIconSize: CGFloat = 17

    var body: some View {
        connectionsList
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
                coordinator.refreshSyncedBackends()
                reload()
            }
            .onReceive(coordinator.dependencies.persistence.connectionsDidChange) { reload() }
    }

    private var connectionsList: some View {
        // Prepare rows on MainActor before SwiftUI requests them during async layout.
        let rows = connections.map { (id: $0.id, content: connectionRow($0)) }
        return VStack(alignment: .leading, spacing: Constants.Connections.cardSpacing) {
            if !connections.isEmpty, showsHeading {
                Text("Saved Connections")
                    .interFont(Constants.Typography.eyebrow)
                    .foregroundStyle(Constants.Connections.sectionForeground(for: colorScheme, contrast: contrast))
                    .accessibilityAddTraits(.isHeader)
            }
            if connections.isEmpty, showsEmptyState {
                Text("No saved connections. Add a connection below to get started.")
                    .interFont(Constants.Typography.bodyS)
                    // No empty-state design reference: preserve its existing semantic light color.
                    .foregroundStyle(colorScheme == .dark
                        ? Constants.Pairing.mutedForeground(for: colorScheme) : Theme.mutedForeground(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("saved-connections.empty")
            } else {
                ForEach(rows, id: \.id) { @Sendable row in row.content }
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
        let status = connection.id == windowConnectionId ? session.connection.connectionState : nil
        return Button {
            if connection.id != windowConnectionId {
                coordinator.onSwitchConnection(id: connection.id)
            }
            onSelection()
        } label: {
            SavedConnectionCard(
                name: connection.displayName,
                address: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)",
                status: status
            )
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("saved-connection.\(connection.id)")
        .accessibilityHint("Touch and hold for connection details and actions.")
        .contextMenu {
            Button { connectionShowingDetails = connection } label: {
                Label {
                    Text("Connection Details").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(.infoCircle)
                        .resizable()
                        .scaledToFit()
                        .frame(width: menuIconSize, height: menuIconSize)
                }
            }
            if supportsMultipleWindows {
                openInNewWindowButton(connection)
            }
            Button(role: .destructive) { connectionPendingDelete = connection } label: {
                Label {
                    Text("Delete").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(.delete)
                        .resizable()
                        .scaledToFit()
                        .frame(width: menuIconSize, height: menuIconSize)
                }
            }
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
            onSelection()
        } label: {
            Label {
                Text("Open in New Window").interFont(Constants.Typography.bodyS)
            } icon: {
                Image(systemName: "macwindow.badge.plus")
            }
        }
    }

    private func delete(_ connection: StoredConnection) {
        let wasBound = connection.id == windowConnectionId
        guard coordinator.onDeleteConnection(id: connection.id) else {
            showDeleteError = true
            return
        }
        reload()
        if wasBound { onSelection() }
    }

    private func reload() {
        guard let records = coordinator.dependencies.persistence.loadConnectionsWithOutcome().connections else { return }
        connections = records.sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }
}

private struct ConnectionPairingActions: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let colorScheme: ColorScheme
    let onPaired: (StoredConnection) -> Void
    @State private var showQRScanner = false
    @State private var showManualEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Connections.rowSpacing) {
            Text("Add Connection")
                .interFont(Constants.Typography.eyebrow)
                .foregroundStyle(Constants.Connections.sectionForeground(for: colorScheme, contrast: contrast))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            ConnectionPairingButtons(
                qrTitle: "Scan QR Code",
                accessibilityPrefix: "saved-connections",
                onScan: { showQRScanner = true },
                onManualEntry: { showManualEntry = true }
            )
        }
        .fullScreenCover(isPresented: $showQRScanner) { QRScannerView(onPaired: onPaired) }
        .sheet(isPresented: $showManualEntry) { ManualTokenEntryView(onPaired: onPaired) }
    }
}
