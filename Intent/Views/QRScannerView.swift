import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var isValidating = false
    @State private var errorMessage: String?

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
        }
    }

    private func handleScannedCode(_ code: String) {
        guard !isValidating else { return }

        // Parse intent://pair?token=...&host=...&port=...&path=/ws&certFingerprint=...
        guard let components = URLComponents(string: code),
              components.scheme == "intent",
              components.host == "pair",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              let hostStr = components.queryItems?.first(where: { $0.name == "host" })?.value,
              let portStr = components.queryItems?.first(where: { $0.name == "port" })?.value,
              let port = Int(portStr) else {
            errorMessage = "Invalid QR code. Make sure you're scanning the code from Intent Settings."
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { errorMessage = nil }
            return
        }

        let certFingerprint = components.queryItems?.first(where: { $0.name == "certFingerprint" })?.value
        let hosts = hostStr.split(separator: ",").map(String.init)

        isValidating = true
        errorMessage = nil

        Task {
            do {
                try await ConnectionManager.shared.connect(hosts: hosts, port: port, token: token, certFingerprint: certFingerprint)
                let server = PairedServer(hosts: hosts, port: port, name: "Intent", pairedAt: Date(), certFingerprint: certFingerprint)
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

