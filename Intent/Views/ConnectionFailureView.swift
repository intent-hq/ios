import SwiftUI

struct ConnectionFailureView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(ConnectionManager.self) var connectionManager
    @Environment(\.colorScheme) var colorScheme
    let errorMessage: String
    var isCertMismatch: Bool = false
    @State private var isRetrying = false
    @State private var attemptNumber = 0
    @State private var retryTask: Task<Void, Never>?
    @State private var savedConnections: [StoredConnection] = []

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            VStack(spacing: Constants.ConnectionFailure.contentSpacing) {
                Spacer()

                // Error icon
                ZStack {
                    Circle()
                        .fill(Theme.destructive(for: colorScheme).opacity(
                            Constants.ConnectionFailure.destructiveBackgroundOpacity))
                        .frame(width: Constants.ConnectionFailure.iconBackgroundSize,
                               height: Constants.ConnectionFailure.iconBackgroundSize)
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: Constants.ConnectionFailure.iconSize))
                        .foregroundStyle(Theme.destructive(for: colorScheme))
                }

                VStack(spacing: Constants.ConnectionFailure.titleSpacing) {
                    Text("Can't Connect")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Constants.ConnectionFailure.messageHorizontalPadding)
                }

                VStack(spacing: Constants.ConnectionFailure.controlSpacing) {
                    // Every observed per-host cert mismatch: on the re-pair
                    // path this lists all mismatching hosts (not just one);
                    // during auto-retry it is the passive list while retries
                    // continue on the remaining hosts.
                    if !connectionManager.certMismatches.isEmpty {
                        CertMismatchListView(mismatches: connectionManager.certMismatches)
                    }

                    // Auto-retry progress
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
                            Constants.ConnectionFailure.controlBackgroundOpacity))
                        .clipShape(RoundedRectangle(
                            cornerRadius: Constants.ConnectionFailure.controlCornerRadius))
                    }

                    // Re-pair button
                    Button {
                        retryTask?.cancel()
                        coordinator.onReconnect()
                    } label: {
                        Label(isCertMismatch ? "Re-pair Device" : "Connect to Different Server",
                              systemImage: isCertMismatch ? "arrow.triangle.2.circlepath" : "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.primary(for: colorScheme))

                    // Other saved connections — switch instead of re-pairing.
                    // Scrollable with a bounded height so a long list never
                    // pushes the controls or rows off a small viewport.
                    if !savedConnections.isEmpty {
                        VStack(alignment: .leading,
                               spacing: Constants.ConnectionFailure.savedConnectionsSpacing) {
                            Text("Saved Connections")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            ScrollView {
                                VStack(spacing: Constants.ConnectionFailure.savedConnectionsSpacing) {
                                    ForEach(savedConnections) { connection in
                                        savedConnectionRow(connection)
                                    }
                                }
                            }
                            .frame(maxHeight: Constants.ConnectionFailure.savedConnectionsMaximumHeight)
                        }
                        .padding(.top, Constants.ConnectionFailure.savedConnectionsSpacing)
                    }
                }
                .padding(.horizontal, Constants.ConnectionFailure.controlsHorizontalPadding)

                Spacer()

                // Help text
                VStack(spacing: Constants.ConnectionFailure.helpSpacing) {
                    Text("Troubleshooting")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text("• Make sure Intent is running on your Mac\n• Check that both devices are on the same network\n• Verify the WebSocket API is enabled in Settings")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, Constants.ConnectionFailure.helpHorizontalPadding)
                .padding(.bottom, Constants.ConnectionFailure.helpBottomPadding)
            }
        }
        .onAppear {
            savedConnections = ConnectionFailureView.alternativeConnections(
                connections: PersistenceManager.shared.loadConnections(),
                activeId: PersistenceManager.shared.activeConnection()?.id)
            if !isCertMismatch {
                startAutoRetry()
            }
        }
        .onDisappear {
            retryTask?.cancel()
        }
    }

    /// True when a connection-failure message describes a certificate
    /// mismatch. Case-insensitive: the aggregate race error starts with
    /// "Certificate fingerprint mismatch...", the coordinator's re-pair
    /// prompt with "Server certificate has changed..." — both must route
    /// to the cert path (no auto-retry, "Re-pair Device" action).
    static func isCertificateMismatchMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("certificate")
    }

    /// Saved connections other than the currently failing active one,
    /// most recently used first.
    static func alternativeConnections(
        connections: [StoredConnection], activeId: UUID?
    ) -> [StoredConnection] {
        connections
            .filter { $0.id != activeId }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    private func savedConnectionRow(_ connection: StoredConnection) -> some View {
        Button {
            retryTask?.cancel()
            coordinator.onSwitchConnection(id: connection.id)
        } label: {
            HStack(spacing: Constants.ConnectionFailure.savedConnectionRowSpacing) {
                Image(systemName: "desktopcomputer")
                    .font(.body)
                    .foregroundStyle(Theme.primary(for: colorScheme))

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
            }
            .padding(.vertical, Constants.ConnectionFailure.savedConnectionVerticalPadding)
            .padding(.horizontal, Constants.ConnectionFailure.savedConnectionHorizontalPadding)
            .background(Theme.muted(for: colorScheme).opacity(
                Constants.ConnectionFailure.controlBackgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: Constants.ConnectionFailure.controlCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func startAutoRetry() {
        retryTask?.cancel()
        retryTask = Task {
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                attemptNumber = attempt
                isRetrying = true

                // Exponential backoff: 2s, 4s, 8s, 16s, max 30s
                let delay = min(
                    Double(1 << min(attempt, Constants.ConnectionFailure.retryBackoffExponentCap)),
                    Constants.ConnectionFailure.retryBackoffMaximum)
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }

                // Try to connect
                guard let pairing = PersistenceManager.shared.loadPairing() else {
                    coordinator.currentScreen = .pairing
                    return
                }

                do {
                    try await ConnectionManager.shared.connect(
                        hosts: pairing.server.hosts,
                        port: pairing.server.port,
                        token: pairing.token,
                        certFingerprint: pairing.server.certFingerprint,
                        tcAddress: pairing.server.tcAddress
                    )
                    // A cancelled retry must never route: the user may have
                    // switched to another saved connection while this connect
                    // was in flight, and a stale success would restore the
                    // failing daemon over the selected one.
                    guard !Task.isCancelled else { return }
                    coordinator.onConnectionSuccess()
                    return
                } catch {
                    // Continue retrying
                    AppLog.connection.warning("[ConnectionFailureView] Retry \(attempt) failed: \(error)")
                }
            }
        }
    }
}

#Preview("Connection Failed") {
    ConnectionFailureView(errorMessage: "The server at 192.168.1.42:5179 is not responding.")
        .environment(AppCoordinator())
        .environment(ConnectionManager.shared)
}

#Preview("Connection Failed - Dark") {
    ConnectionFailureView(errorMessage: "Connection timed out after 10 seconds.")
        .environment(AppCoordinator())
        .environment(ConnectionManager.shared)
        .preferredColorScheme(.dark)
}

