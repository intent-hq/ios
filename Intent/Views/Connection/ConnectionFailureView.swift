import SwiftUI

struct ConnectionFailureView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) var colorScheme
    let errorMessage: String
    var isCertMismatch: Bool = false
    var retryPolicy: ConnectionFailureRetryPolicy = .automaticConnection
    @State private var isRetrying = false
    @State private var attemptNumber = 0
    @State private var retryTask: Task<Void, Never>?
    @State private var savedConnections: [StoredConnection] = []

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            failureContent
        }
        .onAppear {
            savedConnections = Self.alternativeConnections(
                connections: PersistenceManager.shared.loadConnections(),
                activeId: coordinator.backendID?.connectionID
            )
            applyRetryPolicy()
        }
        .onChange(of: retryPolicy) {
            applyRetryPolicy()
        }
        .onChange(of: isCertMismatch) {
            applyRetryPolicy()
        }
        .onDisappear {
            stopAutoRetry()
        }
    }

    private var failureContent: some View {
        VStack(spacing: Constants.ConnectionFailure.contentSpacing) {
            Spacer()
            failureIcon
            failureTitle
            failureControls
            Spacer()
            helpText
        }
    }

    private var failureIcon: some View {
        ZStack {
            Circle()
                .fill(Theme.destructive(for: colorScheme).opacity(
                    Constants.ConnectionFailure.destructiveBackgroundOpacity
                ))
                .frame(
                    width: Constants.ConnectionFailure.iconBackgroundSize,
                    height: Constants.ConnectionFailure.iconBackgroundSize
                )
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: Constants.ConnectionFailure.iconSize))
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .accessibilityHidden(true)
        }
    }

    private var failureTitle: some View {
        VStack(spacing: Constants.ConnectionFailure.titleSpacing) {
            Text(retryPolicy == .manualLogOff ? "Disconnected, but Not Forgotten" : "Can't Connect")
                .font(.title2.bold())
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Constants.ConnectionFailure.messageHorizontalPadding)
        }
    }

    private var failureControls: some View {
        VStack(spacing: Constants.ConnectionFailure.controlSpacing) {
            certificateMismatches
            retryProgress
            manualLogOffButton
            reconnectButton
            savedConnectionsSection
        }
        .padding(.horizontal, Constants.ConnectionFailure.controlsHorizontalPadding)
    }

    @ViewBuilder
    private var certificateMismatches: some View {
        if !session.connection.certMismatches.isEmpty {
            CertMismatchListView(mismatches: session.connection.certMismatches)
        }
    }

    @ViewBuilder
    private var retryProgress: some View {
        if isRetrying {
            HStack(spacing: Constants.ConnectionFailure.progressSpacing) {
                ProgressView()
                if attemptNumber > 1 {
                    Text("Attempt \(attemptNumber)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Constants.ConnectionFailure.controlVerticalPadding)
            .background(Theme.muted(for: colorScheme).opacity(
                Constants.ConnectionFailure.controlBackgroundOpacity
            ))
            .clipShape(RoundedRectangle(cornerRadius: Constants.ConnectionFailure.controlCornerRadius))
        }
    }

    @ViewBuilder
    private var manualLogOffButton: some View {
        if retryPolicy == .manualLogOff {
            Button {
                stopAutoRetry()
                coordinator.onLogOff()
            } label: {
                Label("Retry Log Off", systemImage: "rectangle.portrait.and.arrow.forward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primary(for: colorScheme))
        }
    }

    private var reconnectButton: some View {
        Button {
            stopAutoRetry()
            coordinator.onReconnect()
        } label: {
            Label(
                isCertMismatch ? "Re-pair Device" : "Connect to Different Server",
                systemImage: isCertMismatch ? "arrow.triangle.2.circlepath" : "link.badge.plus"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Theme.primary(for: colorScheme))
    }

    @ViewBuilder
    private var savedConnectionsSection: some View {
        if !savedConnections.isEmpty {
            VStack(alignment: .leading, spacing: Constants.ConnectionFailure.savedConnectionsSpacing) {
                Text("Saved Connections")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                ScrollView {
                    VStack(spacing: Constants.ConnectionFailure.savedConnectionsSpacing) {
                        ForEach(savedConnections) { savedConnectionRow($0) }
                    }
                }
                .frame(maxHeight: Constants.ConnectionFailure.savedConnectionsMaximumHeight)
            }
            .padding(.top, Constants.ConnectionFailure.savedConnectionsSpacing)
        }
    }

    private var helpText: some View {
        VStack(spacing: Constants.ConnectionFailure.helpSpacing) {
            Text(retryPolicy == .manualLogOff ? "Connection Kept" : "Troubleshooting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text(retryPolicy == .manualLogOff
                 ? "Your saved connection and settings were kept so you can retry logging off."
                 : "• Make sure Intent is running on your Mac\n• Check that both devices are on the same network\n• Verify the WebSocket API is enabled in Settings")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Constants.ConnectionFailure.helpHorizontalPadding)
        .padding(.bottom, Constants.ConnectionFailure.helpBottomPadding)
    }

    /// True when a connection-failure message describes a certificate
    /// mismatch. Case-insensitive: the aggregate race error starts with
    /// "Certificate fingerprint mismatch...", the coordinator's re-pair
    /// prompt with "Server certificate has changed..." — both must route
    /// to the cert path (no auto-retry, "Re-pair Device" action).
    static func isCertificateMismatchMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("certificate")
    }

    /// The saved record auto-retry dials: this window's own bound
    /// connection resolved from the saved list — never the global pairing
    /// record, so a retry success reconnects this window's backend instead
    /// of retargeting it at the last-used one (window model v2). Nil —
    /// unbound window, or the record was deleted mid-failure — means there
    /// is nothing to dial.
    static func autoRetryConnection(
        connections: [StoredConnection],
        windowConnectionID: UUID?
    ) -> StoredConnection? {
        guard let windowConnectionID else { return nil }
        return connections.first { $0.id == windowConnectionID }
    }

    /// Saved connections other than this window's currently failing bound
    /// one, most recently used first.
    static func alternativeConnections(
        connections: [StoredConnection],
        activeId: UUID?
    ) -> [StoredConnection] {
        connections
            .filter { $0.id != activeId }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    private func savedConnectionRow(_ connection: StoredConnection) -> some View {
        Button {
            stopAutoRetry()
            coordinator.onSwitchConnection(id: connection.id)
        } label: {
            HStack(spacing: Constants.ConnectionFailure.savedConnectionRowSpacing) {
                Image(systemName: "desktopcomputer")
                    .font(.body)
                    .foregroundStyle(Theme.primary(for: colorScheme))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Constants.ConnectionFailure.savedConnectionTextSpacing) {
                    Text(connection.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Constants.ConnectionFailure.savedConnectionVerticalPadding)
            .padding(.horizontal, Constants.ConnectionFailure.savedConnectionHorizontalPadding)
            .background(Theme.muted(for: colorScheme).opacity(
                Constants.ConnectionFailure.controlBackgroundOpacity
            ))
            .clipShape(RoundedRectangle(cornerRadius: Constants.ConnectionFailure.controlCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func applyRetryPolicy() {
        stopAutoRetry()
        if retryPolicy == .automaticConnection, !isCertMismatch {
            startAutoRetry()
        }
    }

    private func stopAutoRetry() {
        retryTask?.cancel()
        retryTask = nil
        isRetrying = false
        attemptNumber = 0
    }

    private func startAutoRetry() {
        retryTask = Task { await runAutoRetryLoop() }
    }

    private func runAutoRetryLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            attemptNumber = attempt
            isRetrying = true
            let delay = min(
                Double(1 << min(attempt, Constants.ConnectionFailure.retryBackoffExponentCap)),
                Constants.ConnectionFailure.retryBackoffMaximum
            )
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { break }
            guard let record = Self.autoRetryConnection(
                connections: PersistenceManager.shared.loadConnections(),
                windowConnectionID: coordinator.backendID?.connectionID
            ) else {
                coordinator.onReconnect()
                return
            }
            do {
                try await session.connection.connect(
                    hosts: record.server.hosts,
                    port: record.server.port,
                    token: record.token,
                    certFingerprint: record.server.certFingerprint,
                    tcAddress: record.server.tcAddress
                )
                guard !Task.isCancelled else { return }
                coordinator.onConnectionSuccess()
                return
            } catch {
                AppLog.connection.warning("[ConnectionFailureView] Retry \(attempt) failed: \(error)")
            }
        }
    }
}

#Preview("Connection Failed") {
    let session = BackendSessionRegistry.shared.makePairingSession()
    ConnectionFailureView(errorMessage: "The server at 192.168.1.42:5179 is not responding.")
        .environment(session)
        .environment(session.makeCoordinator())
}

#Preview("Connection Failed - Dark") {
    let session = BackendSessionRegistry.shared.makePairingSession()
    ConnectionFailureView(errorMessage: "Connection timed out after 10 seconds.")
        .environment(session)
        .environment(session.makeCoordinator())
        .preferredColorScheme(.dark)
}
