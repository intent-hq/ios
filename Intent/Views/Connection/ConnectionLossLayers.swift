import SwiftUI

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
                    machineName: coordinator.showsReadOnlyBanner ? coordinator.connectionDisplayName : nil,
                    startupState: connection.startupState
                ),
                mismatches: connection.certMismatches,
                onHome: coordinator.onReturnToSavedMachines,
                onRetry: connection.retryConnection
            )
        }
    }
}
