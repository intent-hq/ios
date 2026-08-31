import SwiftUI

struct PairingView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var showQRScanner = false
    @State private var showManualEntry = false
    @State private var showConnections = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    // Header
                    VStack(spacing: 8) {
                        IntentLogo()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Theme.primary(for: colorScheme))

                        Text("Connect to Intent")
                            .font(.title2.bold())
                            .foregroundStyle(Theme.foreground(for: colorScheme))

                        Text("Pair with your desktop app to manage workspaces and chat with agents")
                            .font(.subheadline)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    // Options
                    VStack(spacing: 12) {
                        PairingOptionButton(
                            icon: "camera.fill",
                            title: "Scan QR Code",
                            subtitle: "Fastest way to connect",
                            colorScheme: colorScheme
                        ) {
                            showQRScanner = true
                        }

                        PairingOptionButton(
                            icon: "keyboard",
                            title: "Manual Connection",
                            subtitle: "Enter IP, port, and token",
                            colorScheme: colorScheme
                        ) {
                            showManualEntry = true
                        }

                        if coordinator.pairingShowsSavedConnections {
                            PairingOptionButton(
                                icon: "clock.arrow.circlepath",
                                title: "Saved Connections",
                                subtitle: "Reconnect to a previously paired daemon",
                                colorScheme: colorScheme
                            ) {
                                showConnections = true
                            }
                        }

                    }
                    .padding(.horizontal, 24)

                    Spacer()
                    Spacer()
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView()
            }
            .sheet(isPresented: $showManualEntry) {
                ManualTokenEntryView()
            }
            .sheet(isPresented: $showConnections) {
                ConnectionsView()
            }
        }
    }
}

struct PairingOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.primary(for: colorScheme))
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .padding(16)
            .background(Theme.card(for: colorScheme))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border(for: colorScheme), lineWidth: 1)
            )
        }
    }
}
