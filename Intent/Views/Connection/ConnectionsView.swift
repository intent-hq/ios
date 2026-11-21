import SwiftUI

enum ConnectionPairing {
    enum PersistenceError: LocalizedError {
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

    static func displayName(fromHostStatus result: Any, shared: Bool = false) -> String? {
        guard let status = result as? [String: Any] else { return nil }
        let keys = shared ? ["collaborationName", "prettyHostname", "hostname"] : ["prettyHostname", "hostname"]
        for key in keys {
            if let raw = status[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

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
        if let result = try? await connection.request(principal.isOwner ? "host.status" : "system.status") {
            displayName = Self.displayName(fromHostStatus: result, shared: !principal.isOwner)
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
        try persistence.prepareInvitedPairing(&candidate, hostname: displayName)
        try Task.checkCancellation()
        try connection.validatePairingAdmission(receipt)
        let outcome = persistence.upsertConnectionWithOutcome(candidate)
        guard !outcome.registryUndecodable else { throw PersistenceError.registryUndecodable }
        guard outcome.persisted else { throw PersistenceError.saveFailed }
        let stored = outcome.connection
        guard persistence.setActiveConnection(id: stored.id) else { throw PersistenceError.saveFailed }
        Task {
            guard (try? connection.validatePairingAdmission(receipt)) != nil else { return }
            await connection.refreshHostRoutes()
            persistence.publishPendingBackends()
        }
        return stored
    }
}

struct ConnectionsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @State private var connections: [StoredConnection] = []
    @State private var connectionShowingDetails: StoredConnection?
    @State private var connectionPendingDelete: StoredConnection?
    @State private var showDeleteError = false
    @ScaledMetric private var menuIconSize: CGFloat = 17
    var isEmbedded = false
    var onCollapse: (() -> Void)?
    var onScanQR: (() -> Void)?
    var onManualPairing: (() -> Void)?

    var body: some View {
        presentation
        .sheet(item: $connectionShowingDetails) { connection in
            SavedConnectionDetails(connection: connection)
        }
        .alert(
            "Remove Connection?",
            isPresented: Binding(
                get: { connectionPendingDelete != nil },
                set: { if !$0 { connectionPendingDelete = nil } }
            ),
            presenting: connectionPendingDelete
        ) { connection in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { delete(connection) }
        } message: { connection in
            Text(connection.id == windowConnectionId
                ? "This is the current connection. Removing it will disconnect you."
                : "This removes the saved connection. You'll need to pair again to reconnect.")
        }
        .alert("Couldn’t Remove Connection", isPresented: $showDeleteError) {
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

    private func collapseSidebar() { onCollapse?() }

    @ViewBuilder private var presentation: some View {
        if isEmbedded {
            VStack(spacing: 0) {
                IPadSidebarHeader(onCollapse: collapseSidebar) {
                    IPadSidebarTitle(title: "Connections")
                } actions: {}
                ScrollView {
                    VStack(spacing: Constants.Connections.cardsToPairingSpacing) {
                        connectionsList
                        ConnectionPairingActions(
                            colorScheme: colorScheme,
                            onPaired: handlePaired,
                            onScanQR: onScanQR,
                            onManualPairing: onManualPairing,
                            isEmbedded: true
                        )
                    }
                    .padding(.horizontal, IPadSidebarStyle.inset)
                    .padding(.bottom, IPadSidebarStyle.inset)
                }
            }
            .background(IPadSidebarStyle.background(for: colorScheme))
        } else {
            sheetPresentation
        }
    }

    private var sheetPresentation: some View {
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
                    connectionsList
                    ConnectionPairingActions(colorScheme: colorScheme, onPaired: handlePaired)
                }
            }
        }
    }

    private var connectionsList: some View {
        let rows = connections.map { (id: $0.id, content: connectionRow($0)) }
        return VStack(spacing: Constants.Connections.cardSpacing) {
            if connections.isEmpty {
                Text("No saved connections. Add a connection below to get started.")
                    .interFont(Constants.Typography.bodyS)
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

    private var windowConnectionId: UUID? {
        coordinator.backendID?.connectionID
    }

    private func connectionRow(_ connection: StoredConnection) -> some View {
        let status = connection.id == windowConnectionId ? session.connection.connectionState : nil
        return Button {
            if connection.id != windowConnectionId {
                coordinator.onSwitchConnection(id: connection.id)
            }
            dismissSheet()
        } label: {
            SavedConnectionCard(
                name: connection.displayName,
                address: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)",
                status: status
            )
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("saved-connection.\(connection.id)")
        .accessibilityHint("Touch and hold for connection details or to remove this connection.")
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
                    Text("Remove Connection").interFont(Constants.Typography.bodyS)
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
            Button("Remove Connection", role: .destructive) { connectionPendingDelete = connection }
        }
    }

    private func openInNewWindowButton(_ connection: StoredConnection) -> some View {
        Button {
            openWindow(value: BackendID(connection: connection))
            dismissSheet()
        } label: {
            Label {
                Text("Open in New Window").interFont(Constants.Typography.bodyS)
            } icon: {
                Image(systemName: "macwindow.badge.plus")
            }
        }
    }

    private func dismissSheet() {
        if !isEmbedded { dismiss() }
    }

    private func handlePaired(_ connection: StoredConnection) {
        dismissSheet()
        coordinator.onPaired(connection)
    }

    private func delete(_ connection: StoredConnection) {
        let wasBound = connection.id == windowConnectionId
        guard coordinator.onDeleteConnection(id: connection.id) else {
            showDeleteError = true
            return
        }
        reload()
        if wasBound { dismissSheet() }
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
    var onScanQR: (() -> Void)?
    var onManualPairing: (() -> Void)?
    var isEmbedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Connections.rowSpacing) {
            Text(isEmbedded ? "NEW CONNECTION" : "Add Connection")
                .interFont(Constants.Typography.eyebrow)
                .foregroundStyle(Constants.Connections.sectionForeground(for: colorScheme, contrast: contrast))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            ConnectionPairingButtons(
                qrTitle: isEmbedded ? "QR Code" : "Scan QR Code",
                accessibilityPrefix: "saved-connections",
                onScan: {
                    if let onScanQR { onScanQR() } else { showQRScanner = true }
                },
                onManualEntry: {
                    if let onManualPairing { onManualPairing() } else { showManualEntry = true }
                }
            )
        }
        .fullScreenCover(isPresented: $showQRScanner) { QRScannerView(onPaired: onPaired) }
        .sheet(isPresented: $showManualEntry) { ManualTokenEntryView(onPaired: onPaired) }
    }
}

struct IPadConnectionsSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.isIPadPaneVisible) private var isPaneVisible
    let onCollapse: () -> Void
    let onScanQR: () -> Void
    let onManualPairing: () -> Void

    var body: some View {
        ZStack {
            RetainedIPadPane(isVisible: coordinator.iPadNavigation.pairing == nil) {
                ConnectionsView(
                    isEmbedded: true,
                    onCollapse: onCollapse,
                    onScanQR: onScanQR,
                    onManualPairing: onManualPairing
                )
            }
            if isPaneVisible, let mode = coordinator.iPadNavigation.pairing {
                IPadPairingSidebar(title: "Connections", mode: mode, onCollapse: onCollapse)
            }
        }
    }
}
