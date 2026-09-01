import SwiftUI

/// Connecting phase overlay: the splash art itself is rendered by RootView in
/// a position shared with the loading phase (so it doesn't reset on the
/// loading → connecting transition). This view adds the small bottom HUD pill
/// (spinner, plus the passive per-host cert-mismatch list when the race has
/// observed any) and owns the connection attempt.
struct ConnectingView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(ConnectionManager.self) var connectionManager

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            // Passive per-host cert-mismatch list: hosts that presented a
            // wrong certificate while the race continues on the others.
            if !connectionManager.certMismatches.isEmpty {
                CertMismatchListView(mismatches: connectionManager.certMismatches)
                    .padding(.horizontal, 32)
            }
            ProgressView()
                .padding(.horizontal, Constants.Connecting.horizontalPadding)
                .padding(.vertical, Constants.Connecting.verticalPadding)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(.bottom, Constants.Connecting.bottomPadding)
        .task {
            await attemptConnection()
        }
    }

    private func attemptConnection() async {
        if DemoMode.pretendPaired {
            // Demo/screenshot mode: no daemon. Mark the connection live so the
            // stores run their normal on-connected fetches (served from
            // DemoFixtures under --demo-data) and go straight to the app.
            ConnectionManager.shared.connectionState = .connected
            await waitForWorkspaceData(timeout: Constants.Connecting.workspaceLoadTimeout)
            coordinator.onConnectionSuccess()
            return
        }

        guard let connection = PersistenceManager.shared.activeConnection() else {
            coordinator.currentScreen = .pairing
            return
        }

        do {
            try await ConnectionManager.shared.connect(
                hosts: connection.server.hosts,
                port: connection.server.port,
                token: connection.token,
                certFingerprint: connection.server.certFingerprint
            )
            PersistenceManager.shared.touchLastConnected(id: connection.id)
            // Wait for WorkspaceStore to finish fetching workspace data before
            // navigating, so the user doesn't see an empty workspace list.
            // WorkspaceStore auto-fetches on .connected and sets lastUpdated
            // when done. Poll with a 5-second timeout to avoid getting stuck.
            await waitForWorkspaceData(timeout: Constants.Connecting.workspaceLoadTimeout)
            coordinator.onConnectionSuccess()
        } catch {
            coordinator.onConnectionFailed(error: error.localizedDescription)
        }
    }

    /// Waits for `WorkspaceStore.shared.lastUpdated` to become non-nil,
    /// indicating that workspace data has been fetched. Gives up after
    /// `timeout` seconds so the app never gets stuck on the loading screen.
    private func waitForWorkspaceData(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while WorkspaceStore.shared.lastUpdated == nil && Date() < deadline {
            try? await Task.sleep(for: Constants.Connecting.workspacePollInterval)
        }
    }
}
