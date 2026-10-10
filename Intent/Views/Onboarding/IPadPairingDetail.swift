import SwiftUI

/// A temporary pairing connection leaves the window's current backend untouched
/// until pairing succeeds. Cancel only removes this detail overlay.
struct IPadPairingDetail: View {
    static let scannerWindowSize: CGFloat = 350
    let mode: IPadPairingMode
    let onCancel: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @State private var pairingSession: BackendSession?

    var body: some View {
        Group {
            if let pairingSession {
                pairingContent
                    .environment(pairingSession)
            } else {
                ProgressView("Preparing connection…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if pairingSession == nil {
                pairingSession = coordinator.dependencies.sessionRegistry.makePairingSession()
            }
        }
        .onDisappear { teardown() }
    }

    @ViewBuilder private var pairingContent: some View {
        switch mode {
        case .qrCode:
            QRScannerView(onPaired: paired, isEmbedded: true, onCancel: cancel)
        case .manual:
            ManualTokenEntryView(onPaired: paired, isEmbedded: true, onCancel: cancel)
        }
    }

    private func paired(_ connection: StoredConnection) {
        coordinator.onIPadPairedConnection(connection)
        onCancel()
    }

    private func cancel() {
        teardown()
        onCancel()
    }

    private func teardown() {
        pairingSession?.teardown()
        pairingSession = nil
    }
}

struct IPadManualPairingSurface<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Cancel", action: onCancel)
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .accessibilityIdentifier("ipad.pairing.cancel")
                .padding(IPadSidebarStyle.inset)
            ScrollView {
                content()
                    .frame(maxWidth: Constants.Pairing.maximumContentWidth)
                    .padding(IPadSidebarStyle.inset)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Constants.Pairing.background(for: colorScheme))
    }
}

struct IPadPairingSidebar: View {
    let title: LocalizedStringKey
    let mode: IPadPairingMode
    let onCollapse: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            IPadSidebarHeader(onCollapse: onCollapse) {
                HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
                    IntentIconButton(icon: .arrowLeft, label: "Back", showsBackground: false) {
                        coordinator.iPadNavigation.cancelPairing()
                    }
                    .accessibilityIdentifier("ipad.pairing.back")
                    IPadSidebarTitle(title: title)
                }
            } actions: {}
            VStack(alignment: .leading, spacing: IPadSidebarStyle.inset) {
                pairingCard
                if mode == .qrCode {
                    Button("Enter connection manually") { coordinator.iPadNavigation.presentPairing(.manual) }
                        .buttonStyle(IntentButtonStyle(variant: .secondary))
                        .accessibilityIdentifier("ipad.pairing.manual")
                }
            }
            .padding(.horizontal, IPadSidebarStyle.inset)
            Spacer(minLength: 0)
        }
        .background(IPadSidebarStyle.background(for: colorScheme))
    }

    private var pairingCard: some View {
        HStack(alignment: .top, spacing: Constants.ConnectionSheet.inset) {
            Image(mode == .qrCode ? .connectQR : .connectManual)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Constants.Connections.infoSpacing) {
                Text(mode == .qrCode ? "QR Code" : "Manual Connection")
                    .interFont(Constants.Typography.bodySEmphasized)
                Text(mode == .qrCode
                     ? "Point at the QR code in the Intent Settings"
                     : "Enter the connection details from Intent Settings")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Constants.ConnectionSheet.inset)
        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        .background(IPadSidebarStyle.selection(for: colorScheme), in: .rect(cornerRadius: Constants.ConnectionSheet.fieldCornerRadius))
    }
}
