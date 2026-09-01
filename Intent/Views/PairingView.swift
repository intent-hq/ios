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

                VStack(spacing: Constants.Pairing.contentSpacing) {
                    Spacer()

                    // Header
                    VStack(spacing: Constants.Pairing.headerSpacing) {
                        IntentLogo()
                            .frame(width: Constants.Pairing.logoSize, height: Constants.Pairing.logoSize)
                            .foregroundStyle(Theme.primary(for: colorScheme))

                        Text("Connect to Intent")
                            .font(.title2.bold())
                            .foregroundStyle(Theme.foreground(for: colorScheme))

                        Text("Pair with your desktop app to manage workspaces and chat with agents")
                            .font(.subheadline)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Constants.Pairing.descriptionHorizontalPadding)
                    }

                    // Options
                    VStack(spacing: Constants.Pairing.optionsSpacing) {
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
                    .padding(.horizontal, Constants.Pairing.optionsHorizontalPadding)

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
            HStack(spacing: Constants.Pairing.optionSpacing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.primary(for: colorScheme))
                    .frame(width: Constants.Pairing.optionIconWidth)

                VStack(alignment: .leading, spacing: Constants.Pairing.optionTextSpacing) {
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
            .padding(Constants.Pairing.optionPadding)
            .background(Theme.card(for: colorScheme))
            .clipShape(.rect(cornerRadius: Constants.Pairing.optionCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.Pairing.optionCornerRadius)
                    .stroke(Theme.border(for: colorScheme), lineWidth: Constants.Pairing.optionBorderWidth)
            )
        }
    }
}
