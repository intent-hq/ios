import SwiftUI

/// Shared passive text for eligible loss and inline startup/failure surfaces.
struct ConnectionNetworkStatusView: View {
    let status: NetworkAvailability.Status
    var statusIdentifier = "connection-network.status"
    var showsReconnecting = true

    var body: some View {
        let message = ConnectionNetworkMessage(status: status)
        if showsReconnecting || message.isUnavailable {
            VStack(spacing: Constants.Root.reconnectButtonTopPadding) {
                Text(message.title)
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(statusIdentifier)
                if let guidance = message.guidance {
                    Text(guidance)
                        .interFont(Constants.Typography.bodyXS)
                        .accessibilityIdentifier("connection-network.guidance")
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
