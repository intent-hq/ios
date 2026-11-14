import SwiftUI

/// Connecting phase overlay: the splash art itself is rendered by RootView in
/// a position shared with the loading phase (so it doesn't reset on the
/// loading → connecting transition). This view presents passive per-host
/// certificate-mismatch warnings and owns the connection attempt.
struct ConnectingView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) private var colorScheme
    var networkStatus: NetworkAvailability.Status = .unknown

    private typealias Layout = Constants.Connecting

    private var statusColorScheme: ColorScheme {
        coordinator.connectingStartedByLaunch ? .light : colorScheme
    }

    var body: some View {
        VStack {
            Spacer()
            if let startup = session.connection.startupState {
                ScrollView {
                    DaemonStartupProgressView(state: startup, onRetry: coordinator.restartConnectionAttempt)
                        .padding()
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            #if DEBUG
            if DemoConnectionLoss.initialDataGate != nil {
                Text(verbatim: String(describing: session.connection.connectionState))
                    .accessibilityIdentifier("demo-connection-startup")
            }
            #endif
            if ConnectionNetworkMessage(status: networkStatus).isUnavailable {
                ConnectionNetworkStatusView(status: networkStatus)
                    .padding(.horizontal, Layout.mismatchHorizontalPadding)
            }
            // Passive per-host cert-mismatch list: hosts that presented a
            // wrong certificate while the race continues on the others.
            if !session.connection.certMismatches.isEmpty {
                CertMismatchListView(
                    mismatches: session.connection.certMismatches,
                    warningForeground: Theme.foreground(for: statusColorScheme)
                )
                .padding(.horizontal, Layout.mismatchHorizontalPadding)
            }
        }
        .foregroundStyle(Theme.foreground(for: statusColorScheme))
        .environment(\.colorScheme, statusColorScheme)
        .padding(.bottom, Layout.contentBottomPadding)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            if !coordinator.connectingStartedByLaunch || session.connection.startupState != nil {
                ConnectionBackButton(action: coordinator.onReturnToSavedMachines)
                    .accessibilityIdentifier("connecting.home")
                    .padding(.horizontal, Constants.ConnectionSheet.inset)
            }
        }
        // Keyed on connectionAttemptId: a connection switch performed while
        // this view is already showing (same screen value) bumps the id to
        // restart the attempt, which a plain one-shot .task would not.
        .task(id: coordinator.connectionAttemptId) {
            await attemptConnection()
        }
    }

    /// The view's single Debug seam: demo/screenshot launches have no daemon,
    /// so mark the connection live and let the stores fetch from fixtures.
    private func connectDemoSessionIfRequested() -> Bool {
        #if DEBUG
        guard DemoMode.pretendPaired, !DemoStartupConnection.isEnabled else { return false }
        session.connection.connectDemo(serveFixtures: DemoMode.isEnabled)
        return true
        #else
        false
        #endif
    }

    /// Connects to the window's saved machine; false when the attempt ended
    /// (failure routed, superseded, or no saved connection).
    private func connectSavedMachine() async -> Bool {
        guard let connection = coordinator.windowConnection else {
            if coordinator.backendID != nil {
                // The bound backend's saved connection was deleted out from
                // under this window; the window root's removal observation
                // closes or rebinds it.
                coordinator.onConnectionFailed(
                    error: String(localized: "This connection is no longer saved.")
                )
            } else {
                coordinator.currentScreen = .pairing
            }
            return false
        }

        let attemptsBefore = session.connection.connectAttemptCount
        do {
            try await DiagnosticConnectContext.$origin.withValue(.saved) {
                try await session.connection.connect(
                    hosts: connection.server.hosts,
                    port: connection.server.port,
                    token: connection.token,
                    certFingerprint: connection.server.certFingerprint,
                    tcAddress: connection.server.tcAddress
                )
            }
        } catch {
            // A bumped connectionAttemptId cancels this task and starts a
            // replacement: the superseded attempt's failure must not stomp
            // the screen the restarted attempt (or the connected UI) owns.
            guard !Task.isCancelled else { return false }
            // This connect started one attempt; any later one replaced it.
            let replaced = session.connection.connectAttemptCount > attemptsBefore + 1
            switch Self.failureOutcome(for: error, replacedByNewerAttempt: replaced) {
            case .leave:
                break
            case .retry:
                if case .connecting = coordinator.currentScreen { coordinator.restartConnectionAttempt() }
            case .show(let message):
                coordinator.onConnectionFailed(error: message)
            }
            return false
        }
        if !PersistenceManager.shared.touchLastConnected(id: connection.id) {
            AppLog.connection.warning("[ConnectingView] Could not persist last-connected timestamp")
        }
        return true
    }

    enum FailureOutcome: Equatable {
        /// Another owner routes the screen.
        case leave
        /// Connect again with the window's current saved record.
        case retry
        case show(String)
    }

    /// What a failed connect does to the screen. A cancellation is never a
    /// connection failure, so its "CancellationError" text never shows:
    /// - Replaced by a newer connect on this session (for example a pairing
    ///   or invite link moving this window to another host): that attempt
    ///   owns the screen.
    /// - Cancelled with no successor (sync refreshed the saved login or route
    ///   during startup admission): try again with the refreshed record, so
    ///   the window is never left on Connecting.
    /// A failed daemon startup is already shown by the startup screen.
    nonisolated static func failureOutcome(for error: any Error, replacedByNewerAttempt: Bool) -> FailureOutcome {
        if error is CancellationError { return replacedByNewerAttempt ? .leave : .retry }
        if case DaemonStartupError.failed = error { return .leave }
        return .show(error.localizedDescription)
    }

    private func attemptConnection() async {
        guard !coordinator.lifecycleState.hasReturnedToSavedMachines else { return }
        let attemptID = coordinator.connectionAttemptId
        if !connectDemoSessionIfRequested() {
            guard await connectSavedMachine() else { return }
        }

        // Wait for WorkspaceStore to finish fetching workspace data before
        // navigating, so the user doesn't see an empty workspace list.
        // WorkspaceStore auto-fetches on .connected and sets lastUpdated
        // when done. Poll with a 5-second timeout to avoid getting stuck.
        do {
            #if DEBUG
            if let gate = DemoConnectionLoss.initialRoutingGate {
                try await DemoFixtures.wait(for: gate)
            }
            #endif
            try await waitForWorkspaceData(timeout: Constants.Connecting.workspaceLoadTimeout)
        } catch {
            // Cancelled mid-wait (attempt restarted or view dismissed): the
            // superseded attempt must not publish success over the screen its
            // replacement owns either (ios#230).
            return
        }
        coordinator.onInitialWorkspaceLoadComplete(attemptID: attemptID)
    }

    /// Waits for the session's `WorkspaceStore.lastUpdated` to become
    /// non-nil, indicating that workspace data has been fetched. Gives up
    /// after `timeout` so the app never gets stuck on the loading screen;
    /// throws `CancellationError` if the attempt is cancelled meanwhile.
    private func waitForWorkspaceData(timeout: Duration) async throws {
        try await LaunchPhaseTimeline.poll(
            until: { session.workspaceStore.lastUpdated != nil },
            timeout: timeout,
            interval: Constants.Connecting.workspacePollInterval
        )
    }
}
