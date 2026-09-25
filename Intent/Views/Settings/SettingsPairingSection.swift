import SwiftUI

struct SettingsPairingSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var showQRScanner = false
    @State private var showManualEntry = false

    var body: some View {
        SettingsSection(title: "PAIR NEW") {
            VStack(spacing: 0) {
                if PairingOption.available(showsSavedConnections: false).contains(.qrScan) {
                    Button { showQRScanner = true } label: {
                        SettingsActionLabel(title: "QR Code", systemImage: "qrcode")
                    }
                    Divider()
                }
                Button { showManualEntry = true } label: {
                    SettingsActionLabel(title: "Manual Connection", systemImage: "keyboard")
                }
            }
            .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
        }
        .sheet(isPresented: $showQRScanner, onDismiss: refreshConnections) { QRScannerView(onPaired: handlePaired) }
        .sheet(isPresented: $showManualEntry, onDismiss: refreshConnections) { ManualTokenEntryView(onPaired: handlePaired) }
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
