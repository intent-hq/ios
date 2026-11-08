import SwiftUI

/// The window's two connection-loss surfaces: the blocking screen once
/// reconnection stops, and the read-only banner while it keeps trying.
struct ConnectionLossLayers: View {
    let coordinator: AppCoordinator
    let connection: any SessionConnectionManaging
    let networkStatus: NetworkAvailability.Status

    var body: some View {
        ZStack {
            ConnectionLossPresenter(
                isPresented: coordinator.showsConnectionLossOverlay,
                mismatches: connection.certMismatches,
                machineName: coordinator.showsConnectionLossOverlay ? coordinator.connectionDisplayName : nil,
                reason: connection.reconnectStopReason,
                networkStatus: networkStatus,
                onHome: coordinator.onReturnToSavedMachines
            )
            ReadOnlyBannerPresenter(
                isPresented: coordinator.showsReadOnlyBanner,
                message: ReadOnlyBannerMessage(
                    networkStatus: networkStatus,
                    machineName: coordinator.showsReadOnlyBanner ? coordinator.connectionDisplayName : nil
                ),
                mismatches: connection.certMismatches,
                onHome: coordinator.onReturnToSavedMachines
            )
        }
    }
}
