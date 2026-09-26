import SwiftUI

/// Only the backdrop ignores safe areas. The action stays inside the window's
/// bottom safe area, independent of any editor/keyboard underneath the block.
struct ConnectionLossOverlay: View {
    private static let maximumContentWidth: CGFloat = 420

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let mismatches: [HostCertMismatch]
    var networkStatus: NetworkAvailability.Status = .unknown
    let onHome: () -> Void

    var body: some View {
        // Minimum viewport height centers short content but lets large text/warnings scroll.
        // swiftlint:disable:next geometry_reader_usage
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Constants.Root.reconnectPanelSpacing) {
                    if ConnectionNetworkMessage(status: networkStatus).isUnavailable {
                        Image(systemName: "wifi.slash")
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .tint(.primary)
                            .accessibilityHidden(true)
                    }
                    ConnectionNetworkStatusView(status: networkStatus, statusIdentifier: "connection-loss.status")
                    if !mismatches.isEmpty {
                        CertMismatchListView(mismatches: mismatches)
                    }
                    #if DEBUG
                    networkDiagnostic
                    #endif
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.maximumContentWidth)
                .padding(Constants.Root.reconnectPanelPadding)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onHome) {
                Text("Back to Home")
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Constants.Root.reconnectButtonTopPadding)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Return to your saved machines without forgetting this connection.")
            .accessibilityIdentifier("connection-loss.home")
            .frame(maxWidth: Self.maximumContentWidth)
            .padding(Constants.Root.reconnectPanelPadding)
            .frame(maxWidth: .infinity)
        }
        .background {
            if reduceTransparency {
                Theme.background(for: colorScheme).ignoresSafeArea()
            } else {
                Color.black.opacity(Constants.Root.reconnectBackdropOpacity)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    #if DEBUG
    @ViewBuilder private var networkDiagnostic: some View {
        if let diagnostics = NetworkCopyDiagnostics.current {
            VStack(alignment: .leading) {
                Text("Network copy diagnostic (not a fix)")
                Text(verbatim: diagnostics.readout)
            }
            .font(.caption2.monospaced())
            .multilineTextAlignment(.leading)
            .accessibilityIdentifier("connection-loss.network-diagnostic")
        }
    }
    #endif
}
