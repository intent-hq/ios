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
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ZStack {
            Constants.Connections.background(for: colorScheme).ignoresSafeArea()
            failureContent
        }
        .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            homeButton
                .padding(.horizontal, Constants.ConnectionSheet.inset)
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
        ScrollView {
            FailurePageLayout {
                VStack(spacing: Constants.ConnectionFailure.contentSpacing) {
                    VStack(spacing: Constants.ConnectionFailure.titleToControlsSpacing) {
                        failureTitle
                        failureControls
                    }
                    savedConnectionsSection
                }
                helpText
            }
            .padding(.horizontal, Constants.ConnectionFailure.pagePadding)
            .padding(.top, Constants.ConnectionFailure.pagePadding)
            .padding(.bottom, Constants.ConnectionFailure.footerBottomPadding)
            .frame(minHeight: viewportHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        // The 48pt export hit target includes space below its text, leaving the
        // visible label above the home indicator while matching the mock's inset.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var failureControls: some View {
        VStack(spacing: Constants.ConnectionFailure.controlSpacing) {
            retryProgress
            manualLogOffButton
            reconnectButton
        }
        .buttonStyle(IntentButtonStyle(variant: .primary))
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
            ProgressView()
                .tint(Constants.Connections.mutedForeground(for: colorScheme))
                .frame(maxWidth: .infinity, minHeight: Constants.ConnectionFailure.controlHeight)
                .background(
                    Constants.Connections.surface(for: colorScheme),
                    in: .rect(cornerRadius: Constants.ConnectionFailure.controlCornerRadius)
                )
                .accessibilityLabel("Reconnecting")
                .accessibilityValue(Text("Attempt \(attemptNumber)"))
        }
    }

    @ViewBuilder
    private var manualLogOffButton: some View {
        if retryPolicy == .manualLogOff {
            Button {
                stopAutoRetry()
                coordinator.onLogOff()
            } label: {
                primaryButtonLabel("Retry Disconnect")
            }
        }
    }

    private var reconnectButton: some View {
        Button(action: returnToSavedMachines) {
            primaryButtonLabel(isCertMismatch ? "Re-pair Device" : "Connect to different server")
        }
        .accessibilityIdentifier("connection-failure.reconnect")
    }

    private func primaryButtonLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .interFont(Constants.Typography.bodySEmphasized)
            .tracking(Constants.Connections.nameTracking)
            .foregroundStyle(Constants.Pairing.foreground(for: .light))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // IntentButtonStyle adds 12pt above and below the label.
            .frame(maxWidth: .infinity, minHeight: Constants.ConnectionFailure.controlLabelHeight)
    }

    @ViewBuilder
    private var savedConnectionsSection: some View {
        if !savedConnections.isEmpty {
            VStack(alignment: .leading, spacing: Constants.ConnectionFailure.savedConnectionsSpacing) {
                ConnectionSheetText(
                    "SAVED CONNECTIONS",
                    style: Constants.Typography.eyebrow,
                    tracking: Constants.ConnectionFailure.eyebrowTracking
                )
                .foregroundStyle(Constants.Connections.mutedForeground(for: colorScheme))
                VStack(spacing: Constants.Connections.cardSpacing) {
                    ForEach(savedConnections) { savedConnectionRow($0) }
                }
            }
        }
    }

    private var helpText: some View {
        VStack(alignment: .leading, spacing: Constants.ConnectionFailure.helpSpacing) {
            ConnectionSheetText(
                retryPolicy == .manualLogOff ? "Connection Kept" : "TROUBLESHOOTING",
                style: Constants.Typography.eyebrow,
                tracking: Constants.ConnectionFailure.eyebrowTracking
            )
                .padding(.bottom, Constants.ConnectionFailure.helpHeadingExtraSpacing)
            Text(retryPolicy == .manualLogOff
                 ? "Your saved connection and settings were kept so you can retry disconnecting."
                 : "• Make sure Intent is running on your Mac\n• Check that both devices are on the same network\n• Verify the WebSocket API is enabled in Settings")
                .interFont(Constants.Typography.subtextXXS)
                .tracking(Constants.Connections.infoTracking)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showingDiagnosticLogs = true
            } label: {
                Text("Export logs")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
                    .frame(maxWidth: .infinity, minHeight: Constants.ConnectionFailure.controlHeight, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(IntentContentButtonStyle())
        }
        .foregroundStyle(Constants.Connections.mutedForeground(for: colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Whether the failure screen may dial the saved record on its own. A
    /// failed Log Off (`.manualLogOff`) never does: the user asked to
    /// disconnect, so re-establishing the session must be an explicit
    /// action — "Retry Disconnect" retries forgetting the record, it does not
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
    private var homeButton: some View {
        ConnectionBackButton(action: returnToSavedMachines)
            .accessibilityIdentifier("connection-failure.home")
    }

    private func returnToSavedMachines() {
        stopAutoRetry()
        coordinator.onReturnToSavedMachines()
    }

    private func savedConnectionRow(_ connection: StoredConnection) -> some View {
        Button {
            stopAutoRetry()
            coordinator.onSwitchConnection(id: connection.id)
        } label: {
            SavedConnectionCard(
                name: connection.displayName,
                address: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)",
                isCurrentWindow: false
            )
        }
        .buttonStyle(IntentContentButtonStyle())
    }

    private var failureTitle: some View {
        VStack(spacing: Constants.ConnectionFailure.titleSpacing) {
            ConnectionSheetText(
                retryPolicy == .manualLogOff ? "Disconnected, but Not Forgotten" : "Can’t Connect",
                style: Constants.Typography.heading2,
                tracking: Constants.Connections.headingTracking
            )
                .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
            ConnectionSheetText("\(errorMessage)", style: Constants.Typography.bodyS)
                .foregroundStyle(Constants.Connections.mutedForeground(for: colorScheme))
            certificateMismatches
            ConnectionNetworkStatusView(status: networkStatus, showsReconnecting: false)
        }
        .multilineTextAlignment(.center)
    }
}

/// Center the main group when space permits, keeping help at the bottom without
/// overlap. In the scroll view a taller intrinsic size makes every section reachable.
private struct FailurePageLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let help = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: proposal.width ?? max(content.width, help.width),
            height: max(proposal.height ?? 0, content.height + Constants.ConnectionFailure.helpTopSpacing + help.height)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        let content = subviews[0].sizeThatFits(proposal)
        let help = subviews[1].sizeThatFits(proposal)
        let helpY = bounds.maxY - help.height
        let contentY = min(
            bounds.midY - content.height / 2,
            helpY - Constants.ConnectionFailure.helpTopSpacing - content.height
        )
        subviews[0].place(at: CGPoint(x: bounds.minX, y: contentY), proposal: proposal)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: helpY), proposal: proposal)
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
