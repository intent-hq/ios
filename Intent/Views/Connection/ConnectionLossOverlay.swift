import SwiftUI

struct ConnectionLossOverlay: View {
    private enum Layout {
        static let maximumContentWidth: CGFloat = 354
        static let contentPadding: CGFloat = 24
        static let markSize: CGFloat = 128
        static let markSpacing: CGFloat = 48
        static let copySpacing: CGFloat = 12
        static let actionSpacing: CGFloat = 40
        static let actionHeight: CGFloat = 48
        static let backdropOpacity = 0.65
        static let titleTracking: CGFloat = -0.36
        static let bodyTracking: CGFloat = -0.16
        static let actionTracking: CGFloat = -0.28
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var viewportHeight: CGFloat = 0
    @State private var bottomBalancePadding: CGFloat = 0
    let mismatches: [HostCertMismatch]
    var machineName: String?
    var reason: String?
    var networkStatus: NetworkAvailability.Status = .unknown
    var sourceColorScheme: ColorScheme = .dark
    let onHome: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Layout.markSpacing) {
                Image(.connectionLossMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Layout.markSize, height: Layout.markSize)
                    .accessibilityHidden(true)
                VStack(spacing: Layout.actionSpacing) {
                    messages
                    homeButton
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: Layout.maximumContentWidth)
            .padding(Layout.contentPadding)
            .padding(.bottom, bottomBalancePadding)
            .frame(maxWidth: .infinity, minHeight: viewportHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .onGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom)
        } action: { padding in
            bottomBalancePadding = padding
        }
        .foregroundStyle(.white)
        .background {
            if reduceTransparency {
                Color(.connectionLossBackdrop).ignoresSafeArea()
            } else {
                Color(.connectionLossBackdrop).opacity(Layout.backdropOpacity)
                    .ignoresSafeArea()
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var messages: some View {
        let message = ConnectionNetworkMessage(status: networkStatus)
        let title: LocalizedStringResource = if let machineName {
            "Can’t reconnect to \(machineName)"
        } else {
            "Can’t reconnect"
        }
        return VStack(spacing: Constants.Root.reconnectPanelSpacing) {
            VStack(spacing: Layout.copySpacing) {
                ConnectionSheetText(
                    "\(Text(title))",
                    style: Constants.Typography.bodyM,
                    tracking: Layout.titleTracking
                )
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("connection-loss.status")
                ConnectionSheetText(
                    "\(reason ?? String(localized: "Reconnection to desktop stopped."))",
                    style: Constants.Typography.bodyS,
                    tracking: Layout.bodyTracking
                )
                .foregroundStyle(sourceColorScheme == .light ? .white : Color(.connectionLossSecondary))
                .accessibilityIdentifier("connection-loss.message")
                if let guidance = message.guidance {
                    Text(guidance)
                        .interFont(Constants.Typography.bodyS)
                        .tracking(Layout.bodyTracking)
                        .accessibilityIdentifier("connection-network.guidance")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !mismatches.isEmpty {
                CertMismatchListView(mismatches: mismatches)
            }
            #if DEBUG
            networkDiagnostic
            #endif
        }
    }

    private var homeButton: some View {
        Button(action: onHome) {
            ConnectionSheetText(
                "Back to Home", style: Constants.Typography.bodySEmphasized, tracking: Layout.actionTracking
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Layout.contentPadding)
            .padding(.vertical, Constants.Root.reconnectButtonTopPadding)
            .frame(minHeight: Layout.actionHeight)
            .foregroundStyle(Color(.connectionLossActionForeground))
            .background(.white, in: .rect(cornerRadius: Constants.Root.reconnectPanelCornerRadius))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityHint("Return to your saved machines without removing this connection.")
        .accessibilityIdentifier("connection-loss.home")
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
