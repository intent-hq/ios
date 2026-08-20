import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    /// When set, pairing success is reported to the presenting context instead
    /// of the first-run coordinator flow.
    var onPaired: ((StoredConnection) -> Void)?
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var pendingPayload: PairingPayload?
    @State private var probedFingerprint: String?
    @State private var showFingerprintConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                QRCameraPreview { code in
                    handleScannedCode(code)
                }
                .ignoresSafeArea()

                // Overlay
                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        if isValidating {
                            ProgressView()
                                .tint(.white)
                            Text("Connecting...")
                                .foregroundStyle(.white)
                                .font(.subheadline)
                        } else if let error = errorMessage {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(error)
                                .foregroundStyle(.white)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("Point at the QR code in Intent Settings")
                                .foregroundStyle(.white)
                                .font(.subheadline)
                        }
                    }
                    .padding(20)
                    .background(.black.opacity(0.7))
                    .cornerRadius(12)
                    .padding(.bottom, 60)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Verify Server Identity", isPresented: $showFingerprintConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingPayload = nil
                    isValidating = false
                }
                Button("Trust & Connect") {
                    if let payload = pendingPayload, let fingerprint = probedFingerprint {
                        pendingPayload = nil
                        connect(payload: payload, certFingerprint: fingerprint)
                    } else {
                        // Unreachable today (the alert is only presented after
                        // both values are set), but keep the scanner recoverable
                        // instead of stuck behind `isValidating` forever.
                        pendingPayload = nil
                        isValidating = false
                    }
                }
            } message: {
                Text("The server's TLS certificate fingerprint is:\n\n\(probedFingerprint ?? "")\n\nDo you trust this server?")
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        guard !isValidating else { return }

        // Parse both pairing-URI dialects (canonical `fp=` and legacy
        // `certFingerprint=`); see PairingPayload.
        guard let payload = PairingPayload.parse(code) else {
            errorMessage = "Invalid QR code. Make sure you're scanning the code from Intent Settings."
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { errorMessage = nil }
            return
        }

        isValidating = true
        errorMessage = nil

        if let fingerprint = payload.certFingerprint {
            connect(payload: payload, certFingerprint: fingerprint)
        } else {
            // The payload carries no fingerprint: never downgrade to plain
            // ws://. Probe the server cert like manual entry does and ask the
            // user to trust it before connecting pinned over wss.
            Task {
                let probed = await CertFingerprintProbe.probeFirst(hosts: payload.hosts, port: payload.port)
                switch CertFingerprintProbe.outcome(forFingerprint: probed) {
                case .confirmFingerprint(let fingerprint):
                    pendingPayload = payload
                    probedFingerprint = fingerprint
                    showFingerprintConfirmation = true
                case .abort(let message):
                    errorMessage = message
                    isValidating = false
                }
            }
        }
    }

    /// Connect over wss with the fingerprint pinned. Every QR pairing path
    /// goes through here with a non-nil fingerprint (from the payload or the
    /// trust-confirmed probe), so scanning can never fall back to plain ws://.
    private func connect(payload: PairingPayload, certFingerprint: String) {
        Task {
            do {
                try await ConnectionManager.shared.connect(hosts: payload.hosts, port: payload.port, token: payload.token, certFingerprint: certFingerprint)
                let server = PairedServer(hosts: payload.hosts, port: payload.port, name: "Intent", pairedAt: Date(), certFingerprint: certFingerprint)
                let stored = await ConnectionPairing.finalize(server: server, token: payload.token)
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

// MARK: - Camera Preview

struct QRCameraPreview: UIViewRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return view
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = UIScreen.main.bounds
        view.layer.addSublayer(previewLayer)

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }

        context.coordinator.session = session

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCodeScanned: (String) -> Void
        var session: AVCaptureSession?
        private var lastScannedCode: String?

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let code = object.stringValue,
                  code != lastScannedCode else { return }
            lastScannedCode = code
            onCodeScanned(code)

            // Reset after 3 seconds to allow re-scanning
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.lastScannedCode = nil
            }
        }
    }
}

