import SwiftUI
@preconcurrency import AVFoundation
import Vision
import VisionKit

struct QRScannerView: View {
    @Environment(AppCoordinator.self) var coordinator
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
    @State private var scannerAvailability: ScannerAvailability = .checking
    @State private var errorAutoClearID: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    switch scannerAvailability {
                    case .checking:
                        Color.black
                            .overlay { ProgressView().tint(.white) }
                    case .available:
                        QRCameraPreview(
                            onCodeScanned: { code in
                                handleScannedCode(code)
                            },
                            onUnavailable: {
                                scannerAvailability = .unavailable
                            }
                        )
                    case .unavailable:
                        Color.black
                            .overlay {
                                Text("Camera scanning isn't available — use manual token entry instead")
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(Constants.QRScanner.unavailableMessagePadding)
                            }
                    }
                }
                .ignoresSafeArea()

                // Overlay
                VStack {
                    Spacer()

                    VStack(spacing: Constants.QRScanner.statusSpacing) {
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
                    .padding(Constants.QRScanner.statusPadding)
                    .background(.black.opacity(Constants.QRScanner.statusBackgroundOpacity))
                    .clipShape(.rect(cornerRadius: Constants.QRScanner.statusCornerRadius))
                    .padding(.bottom, Constants.QRScanner.statusBottomPadding)
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
            .task {
                await prepareScanner()
            }
            .task(id: errorAutoClearID) {
                guard errorAutoClearID != nil else { return }
                do {
                    try await Task.sleep(for: Constants.QRScanner.errorDisplayDuration)
                } catch {
                    return
                }
                errorMessage = nil
                errorAutoClearID = nil
            }
        }
    }

    private func prepareScanner() async {
        guard DataScannerViewController.isSupported else {
            scannerAvailability = .unavailable
            return
        }

        let isAuthorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }

        guard !Task.isCancelled else { return }
        scannerAvailability = isAuthorized && DataScannerViewController.isAvailable
            ? .available
            : .unavailable
    }

    private func handleScannedCode(_ code: String) {
        guard !isValidating else { return }

        // Parse both pairing-URI dialects (canonical `fp=` and legacy
        // `certFingerprint=`); see PairingPayload.
        guard let payload = PairingPayload.parse(code) else {
            errorMessage = "Invalid QR code. Make sure you're scanning the code from Intent Settings."
            errorAutoClearID = UUID()
            return
        }

        isValidating = true
        errorAutoClearID = nil
        errorMessage = nil

        // A payload fingerprint is pinned directly; without one, PairingFlow
        // probes the server cert like manual entry does and the user must
        // trust it before connecting pinned over wss — never plain ws://.
        Task {
            switch await PairingFlow.resolveFingerprint(for: payload) {
            case .pinned(let fingerprint):
                connect(payload: payload, certFingerprint: fingerprint)
            case .needsUserConfirmation(let fingerprint):
                pendingPayload = payload
                probedFingerprint = fingerprint
                showFingerprintConfirmation = true
            case .failed(let message):
                errorAutoClearID = nil
                errorMessage = message
                isValidating = false
            }
        }
    }

    /// Connect over wss with the fingerprint pinned. Every QR pairing path
    /// goes through here with a non-nil fingerprint (from the payload or the
    /// trust-confirmed probe), so scanning can never fall back to plain ws://.
    private func connect(payload: PairingPayload, certFingerprint: String) {
        Task {
            do {
                let stored = try await PairingFlow.connect(
                    payload: payload, certFingerprint: certFingerprint)
                dismiss()
                if let onPaired {
                    onPaired(stored)
                } else {
                    coordinator.onConnectionSuccess()
                }
            } catch {
                errorAutoClearID = nil
                errorMessage = "Connection failed: \(error.localizedDescription)"
                isValidating = false
            }
        }
    }
}

private enum ScannerAvailability {
    case checking
    case available
    case unavailable
}

// MARK: - Camera Preview

struct QRCameraPreview: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        context.coordinator.startScanning(scanner)
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCodeScanned = onCodeScanned
        context.coordinator.onUnavailable = onUnavailable
        context.coordinator.startScanning(scanner)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onUnavailable: onUnavailable)
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.deactivate()
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCodeScanned: (String) -> Void
        var onUnavailable: () -> Void
        private weak var scanner: DataScannerViewController?
        private var lastScannedCode: String?
        private var resetTask: Task<Void, Never>?
        private var isActive = true

        init(onCodeScanned: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onCodeScanned = onCodeScanned
            self.onUnavailable = onUnavailable
        }

        func startScanning(_ scanner: DataScannerViewController) {
            guard isActive else { return }
            self.scanner = scanner
            guard !scanner.isScanning else { return }
            do {
                try scanner.startScanning()
            } catch {
                reportUnavailableIfNeeded(for: scanner)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            process(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            process(updatedItems)
        }

        private func process(_ items: [RecognizedItem]) {
            let firstCode = items.lazy.compactMap { item -> String? in
                guard case .barcode(let barcode) = item else { return nil }
                return barcode.payloadStringValue
            }.first
            guard let code = firstCode,
                  code != lastScannedCode else { return }
            lastScannedCode = code
            onCodeScanned(code)

            // Reset after 3 seconds to allow re-scanning
            resetTask?.cancel()
            resetTask = Task { [weak self] in
                try? await Task.sleep(for: Constants.QRScanner.duplicateScanResetDelay)
                guard !Task.isCancelled,
                      let self,
                      self.lastScannedCode == code else { return }
                self.lastScannedCode = nil
                guard self.isActive, let scanner = self.scanner else { return }
                scanner.stopScanning()
                self.startScanning(scanner)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            reportUnavailableIfNeeded(for: dataScanner)
        }

        func deactivate() {
            isActive = false
            scanner = nil
            resetTask?.cancel()
            resetTask = nil
        }

        private func reportUnavailableIfNeeded(for scanner: DataScannerViewController) {
            guard isActive, !scanner.isScanning else { return }
            isActive = false
            onUnavailable()
        }
    }
}

