import SwiftUI

struct BonjourTokenEntryView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    let serverName: String
    let host: String
    let port: Int
    let certFingerprint: String?
    @State private var showQRScanner = false
    @State private var token = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.primary(for: colorScheme))
                        Text("Authenticate")
                            .font(.title3.bold())
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                        Text(serverName)
                            .font(.subheadline)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                    .padding(.top, 32)

                    VStack(spacing: 12) {
                        PairingOptionButton(
                            icon: "camera.fill",
                            title: "Scan QR Code",
                            subtitle: "Show QR code in Intent Settings",
                            colorScheme: colorScheme
                        ) {
                            showQRScanner = true
                        }

                        VStack(spacing: 8) {
                            HStack {
                                TextField("Paste API token", text: $token)
                                    .font(.system(.body, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)

                                Button {
                                    if let clipboard = UIPasteboard.general.string {
                                        token = clipboard
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundStyle(Theme.primary(for: colorScheme))
                                }
                            }

                            if let error = errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(Theme.destructive(for: colorScheme))
                            }

                            Button {
                                validateAndConnect()
                            } label: {
                                if isValidating {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Connect")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.primary(for: colorScheme))
                            .disabled(token.isEmpty || isValidating)
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    Text("Open Intent Settings on your Mac and show the QR code or copy the API token.")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Authenticate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView()
            }
        }
    }

    private func validateAndConnect() {
        isValidating = true
        errorMessage = nil

        Task {
            do {
                try await ConnectionManager.shared.connect(hosts: [host], port: port, token: token, certFingerprint: certFingerprint)
                let server = PairedServer(hosts: [host], port: port, name: serverName, pairedAt: Date(), certFingerprint: certFingerprint)
                PersistenceManager.shared.savePairing(server: server, token: token)
                dismiss()
                coordinator.onConnectionSuccess()
            } catch {
                errorMessage = "Connection failed: \(error.localizedDescription)"
                isValidating = false
            }
        }
    }
}

