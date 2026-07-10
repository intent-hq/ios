import CryptoKit
import SwiftUI

struct ManualTokenEntryView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var host = ""
    @State private var port = "5180"
    @State private var token = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var probedFingerprint: String?
    @State private var showFingerprintConfirmation = false
    @State private var connectTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Image(systemName: "keyboard")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.primary(for: colorScheme))
                            Text("Manual Connection")
                                .font(.title3.bold())
                                .foregroundStyle(Theme.foreground(for: colorScheme))
                        }
                        .padding(.top, 32)

                        VStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Host")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                TextField("192.168.1.42", text: $host)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Port")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                TextField("5180", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("API Token")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                HStack {
                                    TextField("Paste token here", text: $token)
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
                            }
                        }
                        .disabled(isValidating)
                        .padding(.horizontal, 24)

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Theme.destructive(for: colorScheme))
                                .padding(.horizontal, 24)
                        }

                        Button {
                            if isValidating {
                                connectTask?.cancel()
                                connectTask = nil
                                isValidating = false
                            } else {
                                validateAndConnect()
                            }
                        } label: {
                            if isValidating {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Cancel")
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Text("Connect")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.primary(for: colorScheme))
                        .disabled(!isValidating && (host.isEmpty || token.isEmpty))
                        .padding(.horizontal, 24)

                        Spacer()
                    }
                }
            }
            .navigationTitle("Manual Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Verify Server Identity", isPresented: $showFingerprintConfirmation) {
                Button("Cancel", role: .cancel) { isValidating = false }
                Button("Trust & Connect") { connectWithFingerprint() }
            } message: {
                Text("The server's TLS certificate fingerprint is:\n\n\(probedFingerprint ?? "")\n\nDo you trust this server?")
            }
        }
    }

    private func validateAndConnect() {
        guard let portNum = Int(port) else {
            errorMessage = "Invalid port number"
            return
        }

        isValidating = true
        errorMessage = nil

        connectTask = Task {
            let fingerprint = await probeCertFingerprint(host: host, port: portNum)

            if let fingerprint = fingerprint {
                probedFingerprint = fingerprint
                showFingerprintConfirmation = true
            } else {
                // No TLS cert (plain WS) — connect directly without pinning
                do {
                    try await ConnectionManager.shared.connect(hosts: [host], port: portNum, token: token)
                    let server = PairedServer(hosts: [host], port: portNum, name: "Intent", pairedAt: Date())
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

    private func connectWithFingerprint() {
        guard let portNum = Int(port), let fingerprint = probedFingerprint else { return }

        Task {
            do {
                try await ConnectionManager.shared.connect(hosts: [host], port: portNum, token: token, certFingerprint: fingerprint)
                let server = PairedServer(hosts: [host], port: portNum, name: "Intent", pairedAt: Date(), certFingerprint: fingerprint)
                PersistenceManager.shared.savePairing(server: server, token: token)
                dismiss()
                coordinator.onConnectionSuccess()
            } catch {
                errorMessage = "Connection failed: \(error.localizedDescription)"
                isValidating = false
            }
        }
    }

    /// Probe the server's TLS certificate fingerprint via an HTTPS health check.
    private nonisolated func probeCertFingerprint(host: String, port: Int) async -> String? {
        let delegate = CertProbeDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(host):\(port)/health") else { return nil }

        do {
            let _ = try await session.data(from: url)
        } catch {
            // Connection may fail (self-signed cert) but we still capture the cert in the delegate
        }

        return delegate.capturedFingerprint
    }
}

// MARK: - Certificate Probe Delegate

private class CertProbeDelegate: NSObject, URLSessionDelegate {
    var capturedFingerprint: String?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if SecTrustGetCertificateCount(serverTrust) > 0,
           let serverCert = SecTrustGetCertificateAtIndex(serverTrust, 0) {
            let certData = SecCertificateCopyData(serverCert) as Data
            let hash = SHA256.hash(data: certData)
            capturedFingerprint = hash.map { String(format: "%02x", $0) }.joined(separator: ":")
        }

        // Accept the self-signed cert for this probe
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

