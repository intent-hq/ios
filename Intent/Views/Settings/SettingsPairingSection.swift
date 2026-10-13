import SwiftUI

struct SettingsPairingSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var showQRScanner = false
    @State private var showManualEntry = false
    var onScanQR: (() -> Void)?
    var onManualPairing: (() -> Void)?

    var body: some View {
        SettingsSection(title: "PAIR NEW") {
            ConnectionPairingButtons(
                qrTitle: "QR Code",
                accessibilityPrefix: "settings.pairing",
                onScan: {
                    if let onScanQR { onScanQR() } else { showQRScanner = true }
                },
                onManualEntry: {
                    if let onManualPairing { onManualPairing() } else { showManualEntry = true }
                }
            )
        }
        .fullScreenCover(isPresented: $showQRScanner, onDismiss: refreshConnections) { QRScannerView(onPaired: handlePaired) }
        .sheet(isPresented: $showManualEntry, onDismiss: refreshConnections) {
            ManualTokenEntryView(onPaired: handlePaired)
                .preferredColorScheme(colorScheme)
        }
    }

    private func refreshConnections() {
        coordinator.refreshSyncedBackends()
    }

    private func handlePaired(_ connection: StoredConnection) {
        showQRScanner = false
        showManualEntry = false
        coordinator.onPaired(connection)
    }
}
