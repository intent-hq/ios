import SwiftUI

/// Confirmation surface for `intent://pair` deep links. Unlike the in-app QR
/// scan — where the user deliberately pointed the camera at their own desktop
/// app — a deep link can be triggered by any web page, so the target
/// host(s)/port are shown and the user must explicitly confirm before any
/// connection is attempted. The connection itself reuses PairingFlow, so the
/// security semantics match QR pairing exactly: payload fingerprint → pinned
/// wss; no fingerprint → cert probe + user trust confirmation; never plain
/// ws://.
struct DeepLinkPairingView: View {
    @Environment(AppCoordinator.self) var coordinator
    let payload: PairingPayload
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var probedFingerprint: String?
    @State private var showFingerprintConfirmation = false
    /// In-flight probe/connect task, cancelled when the sheet goes away so a
    /// dismissed pairing can't complete (and persist + navigate) afterwards.
    @State private var pairingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    ForEach(payload.hosts, id: \.self) { host in
                        Label {
                            Text(verbatim: "\(host):\(payload.port)")
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                    }
                    if let tcAddress = payload.tcAddress {
                        Label {
                            Text(tcAddress)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                        }
                    }
                }

                Section {
                    Button {
                        startPairing()
                    } label: {
                        if isValidating {
                            HStack {
                                ProgressView()
                                Text("Connecting...")
                            }
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(isValidating)
                } footer: {
                    Text("Only connect if you opened this link yourself, e.g. from your Intent desktop app.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair with Intent?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.pendingDeepLinkPairing = nil }
                }
            }
            // Covers the toolbar Cancel and every other dismissal (swipe
            // down): pairing must not complete after the sheet is gone.
            .onDisappear { pairingTask?.cancel() }
            .alert("Verify Server Identity", isPresented: $showFingerprintConfirmation) {
                Button("Cancel", role: .cancel) {
                    isValidating = false
                }
                Button("Trust & Connect") {
                    if let fingerprint = probedFingerprint {
                        connect(certFingerprint: fingerprint)
                    } else {
                        // Unreachable today (the alert is only presented after
                        // the fingerprint is set), but keep the sheet
                        // recoverable instead of stuck behind isValidating.
                        isValidating = false
                    }
                }
            } message: {
                Text("The server's TLS certificate fingerprint is:\n\n\(probedFingerprint ?? "")\n\nDo you trust this server?")
            }
        }
    }

    private func startPairing() {
        guard !isValidating else { return }
        isValidating = true
        errorMessage = nil

        // Same pinning rules as QR pairing (PairingFlow): a payload
        // fingerprint is pinned directly; without one the server cert is
        // probed and the user must trust it — never plain ws://.
        pairingTask = Task {
            let resolution = await PairingFlow.resolveFingerprint(for: payload)
            guard !Task.isCancelled else { return }
            switch resolution {
            case .pinned(let fingerprint):
                connect(certFingerprint: fingerprint)
            case .needsUserConfirmation(let fingerprint):
                probedFingerprint = fingerprint
                showFingerprintConfirmation = true
            case .failed(let message):
                errorMessage = message
                isValidating = false
            }
        }
    }

    private func connect(certFingerprint: String) {
        pairingTask = Task {
            do {
                let stored = try await PairingFlow.connect(
                    payload: payload, certFingerprint: certFingerprint)
                guard !Task.isCancelled else { return }
                coordinator.onDeepLinkPaired(stored)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Connection failed: \(error.localizedDescription)"
                isValidating = false
            }
        }
    }
}
