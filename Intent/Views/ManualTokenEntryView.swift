import SwiftUI

/// Classification of the manual-entry "Host / Tailcat Address" input: a
/// direct host/IP dialed as today, or a tailcat tunnel address dialed via
/// TailcatKit. Mirrors cloudlands-fe's shared `isTcAddress` predicate
/// (PROTOCOL §12.3): tc addresses are daemon-minted lowercase with the
/// `tc-` prefix, and the check stays a cheap prefix test on purpose — the
/// tunnel dial itself is the authoritative validation.
enum ManualConnectionInput: Equatable {
    case direct(host: String)
    case tailcat(tcAddress: String)

    static func classify(_ raw: String) -> ManualConnectionInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("tc-") {
            // Lowercase like cloudlands-fe does for its dial: tc addresses
            // are daemon-minted lowercase, so a hand-typed `TC-…` still
            // dials.
            return .tailcat(tcAddress: trimmed.lowercased())
        }
        return .direct(host: trimmed)
    }

    /// Direct hosts to race and persist: empty for a tunnel-only target
    /// (the post-connect route refresh fills in daemon-reported IPs).
    var hosts: [String] {
        switch self {
        case .direct(let host): [host]
        case .tailcat: []
        }
    }

    /// tc address to race the tunnel with; persisted on the paired server so
    /// reconnects race the tunnel route too.
    var tcAddress: String? {
        switch self {
        case .direct: nil
        case .tailcat(let tcAddress): tcAddress
        }
    }
}

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
    /// The classified target whose fingerprint was probed, captured alongside
    /// `probedFingerprint` so the confirmation alert connects to exactly the
    /// target the user confirmed — never a re-classification of a possibly
    /// edited field.
    @State private var probedInput: ManualConnectionInput?
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
                                Text("Host / Tailcat Address")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                TextField("192.168.1.42 or tc-…", text: $host)
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
        let input = ManualConnectionInput.classify(host)

        isValidating = true
        errorMessage = nil

        connectTask = Task {
            let fingerprint: String?
            switch input {
            case .direct(let host):
                fingerprint = await CertFingerprintProbe.probe(host: host, port: portNum)
            case .tailcat(let tcAddress):
                do {
                    fingerprint = try await CertFingerprintProbe.probeViaTunnel(
                        dialer: ConnectionManager.shared.tunnelDialer,
                        tcAddress: tcAddress, remotePort: portNum)
                } catch {
                    // A failed dial is the authoritative "invalid or
                    // unreachable Tailcat address" signal (classification is
                    // only a prefix test).
                    guard !Task.isCancelled else { return }
                    errorMessage = "Could not reach the Tailcat address: \(error.localizedDescription)"
                    isValidating = false
                    return
                }
            }

            // The user may have hit Cancel while the probe was in flight: a
            // cancelled direct probe surfaces here as a nil fingerprint (the
            // tunnel branch handles its thrown cancellation above), and
            // processing it would show a spurious certificate error (or
            // clobber the state of a newer attempt). Drop the result instead.
            guard !Task.isCancelled else { return }

            switch CertFingerprintProbe.outcome(forFingerprint: fingerprint) {
            case .confirmFingerprint(let fingerprint):
                probedFingerprint = fingerprint
                probedInput = input
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
        guard let portNum = Int(port), let fingerprint = probedFingerprint,
              let input = probedInput else { return }

        Task {
            do {
                try await ConnectionManager.shared.connect(
                    hosts: input.hosts, port: portNum, token: token,
                    certFingerprint: fingerprint, tcAddress: input.tcAddress)
                let server = PairedServer(
                    hosts: input.hosts, port: portNum, name: "Intent", pairedAt: Date(),
                    certFingerprint: fingerprint, tcAddress: input.tcAddress)
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

