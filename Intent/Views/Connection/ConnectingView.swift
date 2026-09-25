import SwiftUI

/// Connecting phase overlay: the splash art itself is rendered by RootView in
/// a position shared with the loading phase (so it doesn't reset on the
/// loading → connecting transition). This view presents passive per-host
/// certificate-mismatch warnings and owns the connection attempt.
struct ConnectingView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    var networkStatus: NetworkAvailability.Status = .unknown

    private typealias Layout = Constants.Connecting

    var body: some View {
        VStack {
            Spacer()
            if DemoConnectionLoss.initialDataGate != nil {
                Text(verbatim: String(describing: session.connection.connectionState))
                    .accessibilityIdentifier("demo-connection-startup")
            }
            if ConnectionNetworkMessage(status: networkStatus).isUnavailable {
                ConnectionNetworkStatusView(status: networkStatus)
                    .padding(.horizontal, Layout.mismatchHorizontalPadding)
            }
            // Passive per-host cert-mismatch list: hosts that presented a
            // wrong certificate while the race continues on the others.
            if !session.connection.certMismatches.isEmpty {
                CertMismatchListView(mismatches: session.connection.certMismatches)
                    .padding(.horizontal, Layout.mismatchHorizontalPadding)
            }
        }
        .padding(.bottom, Layout.contentBottomPadding)
        // Keyed on connectionAttemptId: a connection switch performed while
        // this view is already showing (same screen value) bumps the id to
        // restart the attempt, which a plain one-shot .task would not.
        .task(id: coordinator.connectionAttemptId) {
            await attemptConnection()
        }
    }

    private func attemptConnection() async {
        guard !coordinator.lifecycleState.hasReturnedToSavedMachines else { return }
        let attemptID = coordinator.connectionAttemptId
        if DemoMode.pretendPaired {
            // Demo/screenshot mode: no daemon. Mark the connection live so the
            // stores run their normal on-connected fetches (served from
            // DemoFixtures under --demo-data) and go straight to the app.
            session.connection.connectionState = .connected
        } else {
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
                return
            }

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
                guard !Task.isCancelled else { return }
                coordinator.onConnectionFailed(error: error.localizedDescription)
                return
            }
            if !PersistenceManager.shared.touchLastConnected(id: connection.id) {
                AppLog.connection.warning("[ConnectingView] Could not persist last-connected timestamp")
            }
        }

        // Wait for WorkspaceStore to finish fetching workspace data before
        // navigating, so the user doesn't see an empty workspace list.
        // WorkspaceStore auto-fetches on .connected and sets lastUpdated
        // when done. Poll with a 5-second timeout to avoid getting stuck.
        do {
            if let gate = DemoConnectionLoss.initialRoutingGate {
                try await DemoFixtures.wait(for: gate)
            }
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
