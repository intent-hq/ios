import SwiftUI

struct ConnectingView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LoadingView(isReconnecting: true)
            .task {
                await attemptConnection()
            }
    }

    private func attemptConnection() async {
        guard let pairing = PersistenceManager.shared.loadPairing() else {
            coordinator.currentScreen = .pairing
            return
        }

        do {
            try await ConnectionManager.shared.connect(
                hosts: pairing.server.hosts,
                port: pairing.server.port,
                token: pairing.token,
                certFingerprint: pairing.server.certFingerprint
            )
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
