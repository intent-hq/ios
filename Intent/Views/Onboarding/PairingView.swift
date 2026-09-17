import SwiftUI

/// The pairing paths PairingView offers, platform-filtered: visionOS exposes
/// no camera to third-party apps, so live QR scanning is not a viable path
/// there and is excluded from the options list.
enum PairingOption: Equatable {
    case manualEntry
    case qrScan
    case savedConnections

    /// Whether live camera QR scanning exists on this platform.
    static var platformSupportsCameraScanning: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    static func available(
        showsSavedConnections: Bool,
        supportsCameraScanning: Bool = platformSupportsCameraScanning
    ) -> [Self] {
        var options: [Self] = []
        if supportsCameraScanning {
            options.append(.qrScan)
        }
        options.append(.manualEntry)
        if showsSavedConnections {
            options.append(.savedConnections)
        }
        return options
    }
}

struct PairingView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var showQRScanner = false
    @State private var showManualEntry = false
    @State private var showConnections = false

    var body: some View {
        NavigationStack {
            pairingContent
                .sheet(isPresented: $showQRScanner) { QRScannerView() }
                .sheet(isPresented: $showManualEntry) { ManualTokenEntryView() }
                .sheet(isPresented: $showConnections) { ConnectionsView() }
        }
    }

    private var pairingContent: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            VStack(spacing: Constants.Pairing.contentSpacing) {
                Spacer()
                pairingHeader
                pairingOptions
                Spacer()
                Spacer()
            }
        }
    }

    private var pairingHeader: some View {
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
    }

    private var pairingOptions: some View {
        let options = PairingOption.available(
            showsSavedConnections: coordinator.pairingShowsSavedConnections
        )
        return VStack(spacing: Constants.Pairing.optionsSpacing) {
            if options.contains(.qrScan) {
                PairingOptionButton(
                    icon: "camera.fill",
                    title: "Scan QR Code",
                    subtitle: "Fastest way to connect",
                    colorScheme: colorScheme
                ) { showQRScanner = true }
            }
            if options.contains(.manualEntry) {
                PairingOptionButton(
                    icon: "keyboard",
                    title: "Manual Connection",
                    subtitle: "Enter IP, port, and token",
                    colorScheme: colorScheme
                ) { showManualEntry = true }
            }
            if options.contains(.savedConnections) {
                PairingOptionButton(
                    icon: "clock.arrow.circlepath",
                    title: "Saved Connections",
                    subtitle: "Reconnect to a previously paired daemon",
                    colorScheme: colorScheme
                ) { showConnections = true }
            }
            visionPairingHint
        }
        .padding(.horizontal, Constants.Pairing.optionsHorizontalPadding)
    }

    @ViewBuilder
    private var visionPairingHint: some View {
        #if os(visionOS)
        Text("Pair from your iPhone or Mac: open the intent://pair link shown in the Intent desktop app.")
            .font(.caption)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .multilineTextAlignment(.center)
        #endif
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
                    .accessibilityHidden(true)

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
                    .accessibilityHidden(true)
            }
            .padding(Constants.Pairing.optionPadding)
            .background(Theme.card(for: colorScheme))
            .clipShape(.rect(cornerRadius: Constants.Pairing.optionCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.Pairing.optionCornerRadius)
                    .stroke(Theme.border(for: colorScheme), lineWidth: Constants.Pairing.optionBorderWidth)
            )
        }
        .visionCardRowButton(cornerRadius: Constants.Pairing.optionCornerRadius)
    }
}
