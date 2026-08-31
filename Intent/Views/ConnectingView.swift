import SwiftUI

/// Connecting phase overlay: the splash art itself is rendered by RootView in
/// a position shared with the loading phase (so it doesn't reset on the
/// loading → connecting transition). This view adds the small bottom HUD pill
/// (spinner only) and owns the connection attempt.
struct ConnectingView: View {
    @Environment(AppCoordinator.self) var coordinator

    var body: some View {
        VStack {
            Spacer()
            ProgressView()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(.bottom, 24)
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
            await waitForWorkspaceData(timeout: 5.0)
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
            await waitForWorkspaceData(timeout: 5.0)
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
        let pollInterval: UInt64 = 100_000_000 // 100ms in nanoseconds
        while WorkspaceStore.shared.lastUpdated == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }
}
