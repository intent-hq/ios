import SwiftUI

/// Connecting phase overlay: the splash art itself is rendered by RootView in
/// a position shared with the loading phase (so it doesn't reset on the
/// loading → connecting transition). This view presents passive per-host
/// certificate-mismatch warnings and owns the connection attempt.
struct ConnectingView: View {
    private static let mismatchHorizontalPadding: CGFloat = 32
    private static let mismatchBottomPadding: CGFloat = 24

    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session

    var body: some View {
        VStack {
            Spacer()
            // Passive per-host cert-mismatch list: hosts that presented a
            // wrong certificate while the race continues on the others.
            if !session.connection.certMismatches.isEmpty {
                CertMismatchListView(mismatches: session.connection.certMismatches)
                    .padding(.horizontal, Self.mismatchHorizontalPadding)
            }
        }
        .padding(.bottom, Self.mismatchBottomPadding)
        // Keyed on connectionAttemptId: a connection switch performed while
        // this view is already showing (same screen value) bumps the id to
        // restart the attempt, which a plain one-shot .task would not.
        .task(id: coordinator.connectionAttemptId) {
            await attemptConnection()
        }
    }

    private func attemptConnection() async {
        if DemoMode.pretendPaired {
            // Demo/screenshot mode: no daemon. Mark the connection live so the
            // stores run their normal on-connected fetches (served from
            // DemoFixtures under --demo-data) and go straight to the app.
            session.connection.connectionState = .connected
            await waitForWorkspaceData(timeout: Constants.Connecting.workspaceLoadTimeout)
            coordinator.onConnectionSuccess()
            return
        }

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
            try await session.connection.connect(
                hosts: connection.server.hosts,
                port: connection.server.port,
                token: connection.token,
                certFingerprint: connection.server.certFingerprint,
                tcAddress: connection.server.tcAddress
            )
            if !PersistenceManager.shared.touchLastConnected(id: connection.id) {
                AppLog.connection.warning("[ConnectingView] Could not persist last-connected timestamp")
            }
            // Wait for WorkspaceStore to finish fetching workspace data before
            // navigating, so the user doesn't see an empty workspace list.
            // WorkspaceStore auto-fetches on .connected and sets lastUpdated
            // when done. Poll with a 5-second timeout to avoid getting stuck.
            await waitForWorkspaceData(timeout: Constants.Connecting.workspaceLoadTimeout)
            coordinator.onConnectionSuccess()
        } catch {
            // A bumped connectionAttemptId cancels this task and starts a
            // replacement: the superseded attempt's failure must not stomp
            // the screen the restarted attempt (or the connected UI) owns.
            guard !Task.isCancelled else { return }
            coordinator.onConnectionFailed(error: error.localizedDescription)
        }
    }

    /// Waits for the session's `WorkspaceStore.lastUpdated` to become
    /// non-nil, indicating that workspace data has been fetched. Gives up
    /// after `timeout` seconds so the app never gets stuck on the loading
    /// screen.
    private func waitForWorkspaceData(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.workspaceStore.lastUpdated == nil, Date() < deadline {
            try? await Task.sleep(for: Constants.Connecting.workspacePollInterval)
        }
    }
}
