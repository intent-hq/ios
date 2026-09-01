import SwiftUI

struct ManualTokenEntryView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    /// When set, pairing success is reported to the presenting context instead
    /// of the first-run coordinator flow.
    var onPaired: ((StoredConnection) -> Void)?
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
                    VStack(spacing: Constants.ManualTokenEntry.contentSpacing) {
                        VStack(spacing: Constants.ManualTokenEntry.headerSpacing) {
                            Image(systemName: "keyboard")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.primary(for: colorScheme))
                            Text("Manual Connection")
                                .font(.title3.bold())
                                .foregroundStyle(Theme.foreground(for: colorScheme))
                        }
                        .padding(.top, Constants.ManualTokenEntry.headerTopPadding)

                        VStack(spacing: Constants.ManualTokenEntry.formSpacing) {
                            VStack(alignment: .leading, spacing: Constants.ManualTokenEntry.fieldSpacing) {
                                Text("Host")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                TextField("192.168.1.42", text: $host)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }

                            VStack(alignment: .leading, spacing: Constants.ManualTokenEntry.fieldSpacing) {
                                Text("Port")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                TextField("5180", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                            }

                            VStack(alignment: .leading, spacing: Constants.ManualTokenEntry.fieldSpacing) {
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
                                    .accessibilityLabel("Paste API token")
                                }
                            }
                        }
                        .disabled(isValidating)
                        .padding(.horizontal, Constants.ManualTokenEntry.horizontalPadding)

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Theme.destructive(for: colorScheme))
                                .padding(.horizontal, Constants.ManualTokenEntry.horizontalPadding)
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
                                HStack(spacing: Constants.ManualTokenEntry.progressSpacing) {
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
                        .padding(.horizontal, Constants.ManualTokenEntry.horizontalPadding)

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
            let fingerprint = await CertFingerprintProbe.probe(host: host, port: portNum)

            // The user may have hit Cancel while the probe was in flight: the
            // cancelled URLSession request surfaces here as a nil fingerprint,
            // and processing it would show a spurious certificate error (or
            // clobber the state of a newer attempt). Drop the result instead.
            guard !Task.isCancelled else { return }

            switch CertFingerprintProbe.outcome(forFingerprint: fingerprint) {
            case .confirmFingerprint(let fingerprint):
                probedFingerprint = fingerprint
                showFingerprintConfirmation = true
            case .abort(let message):
                // Never connect unpinned: without a probed certificate there is
                // no way to verify the server's identity.
                errorMessage = message
                isValidating = false
            }
        }
    }

    private func connectWithFingerprint() {
        guard let portNum = Int(port), let fingerprint = probedFingerprint else { return }

        Task {
            do {
                try await ConnectionManager.shared.connect(hosts: [host], port: portNum, token: token, certFingerprint: fingerprint)
                let server = PairedServer(hosts: [host], port: portNum, name: "Intent", pairedAt: Date(), certFingerprint: fingerprint)
                let stored = await ConnectionPairing.finalize(server: server, token: token)
                dismiss()
                if let onPaired {
                    onPaired(stored)
                } else {
                    coordinator.onConnectionSuccess()
                }
            } catch {
                errorMessage = "Connection failed: \(error.localizedDescription)"
                isValidating = false
            }
        }
    }

}

