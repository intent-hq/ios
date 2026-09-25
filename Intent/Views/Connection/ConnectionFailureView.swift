import SwiftUI

struct ConnectionFailureView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) var colorScheme
    let errorMessage: String
    var isCertMismatch: Bool = false
    var retryPolicy: ConnectionFailureRetryPolicy = .automaticConnection
    var networkStatus: NetworkAvailability.Status = .unknown
    @State private var isRetrying = false
    @State private var attemptNumber = 0
    @State private var retryTask: Task<Void, Never>?
    @State private var savedConnections: [StoredConnection] = []
    @State private var showingDiagnosticLogs = false

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
        .onChange(of: retryPolicy) { applyRetryPolicy() }
        .onChange(of: isCertMismatch) { applyRetryPolicy() }
        .onDisappear {
            stopAutoRetry()
        }
        .sheet(isPresented: $showingDiagnosticLogs) {
            DiagnosticExportView()
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

    private var failureControls: some View {
        VStack(spacing: Constants.ConnectionFailure.controlSpacing) {
            certificateMismatches
            retryProgress
            manualLogOffButton
            reconnectButton
            savedConnectionsSection
            Button {
                showingDiagnosticLogs = true
            } label: {
                Label { Text("Export logs").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "doc.zipper") }
            }
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
                        .interFont(Constants.Typography.subtextXXS)
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
                Label { Text("Retry Log Off").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "rectangle.portrait.and.arrow.forward") }
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
            Label {
                Text(isCertMismatch ? "Re-pair Device" : "Connect to Different Server").interFont(Constants.Typography.bodyS)
            } icon: {
                Image(systemName: isCertMismatch ? "arrow.triangle.2.circlepath" : "link.badge.plus")
            }
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
                    .interFont(Constants.Typography.eyebrow.withFace(.semibold))
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
                .interFont(Constants.Typography.eyebrow.withFace(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text(retryPolicy == .manualLogOff
                 ? "Your saved connection and settings were kept so you can retry logging off."
                 : "• Make sure Intent is running on your Mac\n• Check that both devices are on the same network\n• Verify the WebSocket API is enabled in Settings")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Constants.ConnectionFailure.helpHorizontalPadding)
        .padding(.bottom, Constants.ConnectionFailure.helpBottomPadding)
    }

    /// True when a connection-failure message describes a certificate
    /// trust failure. Case-insensitive: the aggregate race error starts with
    /// "Certificate fingerprint mismatch...", the coordinator's re-pair
    /// prompt with "Server certificate has changed...", and a saved record
    /// without a pin is refused with "No trusted certificate is saved..." —
    /// all must route to the cert path (no auto-retry, "Re-pair Device"
    /// action; the saved record is kept).
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
                        .interFont(Constants.Typography.bodyXSEmphasized)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                        .interFont(Constants.Typography.subtextXXS)
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

    /// Whether the failure screen may dial the saved record on its own. A
    /// failed Log Off (`.manualLogOff`) never does: the user asked to
    /// disconnect, so re-establishing the session must be an explicit
    /// action — "Retry Log Off" retries forgetting the record, it does not
    /// reconnect (ios#235). Certificate failures route to re-pairing.
    static func shouldAutoRetry(
        retryPolicy: ConnectionFailureRetryPolicy,
        isCertMismatch: Bool
    ) -> Bool {
        retryPolicy == .automaticConnection && !isCertMismatch
    }

    /// Exponential backoff: 2s, 4s, 8s, 16s, max 30s.
    static func retryBackoff(attempt: Int) -> Duration {
        .seconds(min(
            Double(1 << min(attempt, Constants.ConnectionFailure.retryBackoffExponentCap)),
            Constants.ConnectionFailure.retryBackoffMaximum
        ))
    }

    /// The auto-retry lifecycle behind the failure screen, independent of
    /// the view so it can be driven against a coordinator and a fake
    /// connection. Returns without dialing when `shouldAutoRetry` is false;
    /// otherwise loops until a dial succeeds (routes via
    /// `onConnectionSuccess`), the bound record disappears (routes to
    /// pairing), or the task is cancelled.
    static func runAutoRetry(
        retryPolicy: ConnectionFailureRetryPolicy,
        isCertMismatch: Bool,
        coordinator: AppCoordinator,
        connection: any SessionConnectionManaging,
        loadConnections: () -> [StoredConnection],
        backoff: (Int) -> Duration = { retryBackoff(attempt: $0) },
        onAttempt: (Int) -> Void = { _ in }
    ) async {
        guard shouldAutoRetry(retryPolicy: retryPolicy, isCertMismatch: isCertMismatch) else {
            return
        }
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            onAttempt(attempt)

            try? await Task.sleep(for: backoff(attempt))
            if Task.isCancelled { break }
            // Home retires the coordinator synchronously, before SwiftUI
            // delivers onDisappear and cancels this view-owned retry task.
            guard !coordinator.lifecycleState.hasReturnedToSavedMachines else { return }

            // Dial this window's own bound record (re-read each
            // attempt so rotated tokens synced mid-retry are used);
            // a missing record routes to pairing instead of dialing
            // another backend's.
            guard let record = autoRetryConnection(
                connections: loadConnections(),
                windowConnectionID: coordinator.backendID?.connectionID
            ) else {
                coordinator.onReconnect()
                return
            }

            do {
                try await DiagnosticConnectContext.$origin.withValue(.failureScreenRetry) {
                    try await connection.connect(
                        hosts: record.server.hosts,
                        port: record.server.port,
                        token: record.token,
                        certFingerprint: record.server.certFingerprint,
                        tcAddress: record.server.tcAddress
                    )
                }
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

    private func applyRetryPolicy() {
        stopAutoRetry()
        if Self.shouldAutoRetry(
            retryPolicy: retryPolicy,
            isCertMismatch: isCertMismatch
        ) {
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
        let retryPolicy = retryPolicy
        let isCertMismatch = isCertMismatch
        retryTask = Task {
            await Self.runAutoRetry(
                retryPolicy: retryPolicy,
                isCertMismatch: isCertMismatch,
                coordinator: coordinator,
                connection: session.connection,
                loadConnections: { PersistenceManager.shared.loadConnections() },
                onAttempt: { attempt in
                    attemptNumber = attempt
                    isRetrying = true
                }
            )
        }
    }
}

extension ConnectionFailureView {
    private var failureTitle: some View {
        VStack(spacing: Constants.ConnectionFailure.titleSpacing) {
            Text(retryPolicy == .manualLogOff ? "Disconnected, but Not Forgotten" : "Can't Connect")
                .interFont(Constants.Typography.heading2.withFace(.bold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text(errorMessage)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Constants.ConnectionFailure.messageHorizontalPadding)
            ConnectionNetworkStatusView(status: networkStatus, showsReconnecting: false)
                .padding(.horizontal, Constants.ConnectionFailure.messageHorizontalPadding)
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
