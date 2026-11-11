import SwiftUI
#if !os(visionOS)
@preconcurrency import AVFoundation
import Vision
import VisionKit
#endif

/// Pure state machine for `QRScannerView` (idle -> validating -> fingerprint
/// confirmation or error), eliminating mutually invalid Boolean/Optional
/// combinations and keeping scan/probe/trust transitions unit-testable without
/// VisionKit camera hardware.
struct QRScannerSessionState: Equatable {
    enum Phase: Equatable {
        case confirmingFingerprint(payload: PairingPayload, fingerprint: String)
        case error(message: String, autoClearID: UUID?)
        case idle
        case validating
    }

    static let invalidCodeMessage = "Invalid QR code. Scan the code from Settings -> Mobile in the desktop app."

    private(set) var phase: Phase = .idle

    var isValidating: Bool {
        switch phase {
        case .validating, .confirmingFingerprint:
            return true
        case .idle, .error:
            return false
        }
    }

    var errorMessage: String? {
        if case let .error(message, _) = phase { return message }
        return nil
    }

    var errorAutoClearID: UUID? {
        if case let .error(_, id) = phase { return id }
        return nil
    }

    var isConfirmingFingerprint: Bool {
        if case .confirmingFingerprint = phase { return true }
        return false
    }

    var probedFingerprint: String? {
        if case let .confirmingFingerprint(_, fingerprint) = phase { return fingerprint }
        return nil
    }

    enum ScanDecision: Equatable {
        case ignoreWhileBusy
        case invalidInput
        case validate(PairingPayload)
    }

    mutating func receiveScannedCode(_ code: String) -> ScanDecision {
        guard !isValidating else { return .ignoreWhileBusy }
        guard let payload = PairingPayload.parse(code) else {
            phase = .error(message: Self.invalidCodeMessage, autoClearID: UUID())
            return .invalidInput
        }
        phase = .validating
        return .validate(payload)
    }

    mutating func requestFingerprintConfirmation(payload: PairingPayload, fingerprint: String) {
        phase = .confirmingFingerprint(payload: payload, fingerprint: fingerprint)
    }

    mutating func consumeConfirmedFingerprint() -> (payload: PairingPayload, fingerprint: String)? {
        guard case let .confirmingFingerprint(payload, fingerprint) = phase else {
            phase = .idle
            return nil
        }
        phase = .validating
        return (payload, fingerprint)
    }

    mutating func cancelConfirmation() {
        if case .confirmingFingerprint = phase {
            phase = .idle
        }
    }

    mutating func fail(_ message: String) {
        phase = .error(message: message, autoClearID: nil)
    }

    mutating func clearError(matching id: UUID) {
        if case let .error(_, currentID) = phase, currentID == id {
            phase = .idle
        }
    }

    mutating func reset() {
        phase = .idle
    }
}

/// Suppresses consecutive scans of the same barcode until its cooldown expires.
struct QRScannerDeduplicator: Equatable {
    private(set) var lastScannedCode: String?

    mutating func accept(_ candidates: [String]) -> String? {
        guard let code = candidates.first, code != lastScannedCode else { return nil }
        lastScannedCode = code
        return code
    }

    mutating func expire(matching code: String) -> Bool {
        guard lastScannedCode == code else { return false }
        lastScannedCode = nil
        return true
    }
}

#if os(visionOS)
/// DataScannerViewController (VisionKit live camera scanning) is unavailable
/// on visionOS; keep the same API so call sites compile, and direct the user
/// to manual token entry.
struct QRScannerView: View {
    @Environment(\.dismiss) var dismiss
    /// Unused on visionOS: kept so call sites pass the same arguments as the
    /// iOS QRScannerView below.
    var onPaired: ((StoredConnection) -> Void)?
    var isEmbedded = false
    var onCancel: (() -> Void)?

    var body: some View {
        NavigationStack {
            Color.black
                .overlay {
                    Text("Camera scanning isn't available — use manual token entry instead")
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(Constants.QRScanner.unavailableMessagePadding)
                }
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        IntentIconButton(icon: .close, label: "Cancel") {
                            if isEmbedded { onCancel?() } else { dismiss() }
                        }
                    }
                    .intentToolbarSurface()
                }
        }
    }
}
#else
struct QRScannerView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.dismiss) var dismiss
    /// When set, pairing success is reported to the presenting context instead
    /// of the first-run coordinator flow.
    var onPaired: ((StoredConnection) -> Void)?
    var isEmbedded = false
    var onCancel: (() -> Void)?
    @State private var scannerState = QRScannerSessionState()
    @State private var scannerAvailability: ScannerAvailability = .checking
    @State private var connectTask: Task<Void, Never>?

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { scannerState.isConfirmingFingerprint },
            set: { presented in
                if !presented { scannerState.cancelConfirmation() }
            }
        )
    }

    var body: some View {
        ZStack {
            scannerLayer
            QRScannerOverlay(
                showsGuide: scannerAvailability == .available,
                isValidating: scannerState.isValidating,
                errorMessage: scannerState.errorMessage,
                isEmbedded: isEmbedded,
                onCancel: cancel
            )
        }
        .preferredColorScheme(isEmbedded ? nil : .dark)
        .environment(\.colorScheme, .dark)
        .alert("Verify Server Identity", isPresented: confirmationBinding) {
            Button("Cancel", role: .cancel) {
                scannerState.cancelConfirmation()
            }
            Button("Trust & Connect") { trustPendingFingerprint() }
        } message: {
            Text("The server's TLS certificate fingerprint is:\n\n\(scannerState.probedFingerprint ?? "")\n\nDo you trust this server?")
        }
        .onDisappear { connectTask?.cancel() }
        .accessibilityAction(.escape, cancel)
        .task { await prepareScanner() }
        .task(id: scannerState.errorAutoClearID) { await clearErrorAfterDelay() }
    }

    private func cancel() {
        connectTask?.cancel()
        connectTask = nil
        scannerState.reset()
        if isEmbedded { onCancel?() } else { dismiss() }
    }

    private var scannerLayer: some View {
        Group {
            switch scannerAvailability {
            case .checking:
                Color.black
                    .overlay { ProgressView().tint(.white) }
            case .available:
                QRCameraPreview(onCodeScanned: handleScannedCode) {
                    scannerAvailability = .unavailable
                }
            case .unavailable:
                Color.black
                    .overlay {
                        Text("Camera scanning isn't available — use manual token entry instead")
                            .interFont(Constants.Typography.bodyS)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(Constants.QRScanner.unavailableMessagePadding)
                    }
            }
        }
        .ignoresSafeArea()
    }

    private func trustPendingFingerprint() {
        guard let confirmed = scannerState.consumeConfirmedFingerprint() else { return }
        connect(payload: confirmed.payload, certFingerprint: confirmed.fingerprint)
    }

    private func clearErrorAfterDelay() async {
        guard let id = scannerState.errorAutoClearID else { return }
        do {
            try await Task.sleep(for: Constants.QRScanner.errorDisplayDuration)
        } catch {
            return
        }
        scannerState.clearError(matching: id)
    }

    private func prepareScanner() async {
        guard DataScannerViewController.isSupported else {
            PairingDiagnostics.scanner(.scannerAvailability, failure: .unavailable)
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
        if !isAuthorized || !DataScannerViewController.isAvailable {
            PairingDiagnostics.scanner(.scannerAvailability, failure: isAuthorized ? .unavailable : .permissionDenied)
        }
        scannerAvailability = isAuthorized && DataScannerViewController.isAvailable
            ? .available
            : .unavailable
    }

    private func handleScannedCode(_ code: String) {
        switch scannerState.receiveScannedCode(code) {
        case .ignoreWhileBusy:
            return
        case .invalidInput:
            PairingDiagnostics.invalidInput()
            return
        case .validate(let payload):
            // A payload fingerprint is pinned directly; without one, PairingFlow
            // probes the server cert like manual entry does and the user must
            // trust it before connecting pinned over wss — never plain ws://.
            connectTask = Task {
                let resolution = await PairingFlow.resolveFingerprint(for: payload)
                guard !Task.isCancelled else { return }
                switch resolution {
                case .pinned(let fingerprint):
                    connect(payload: payload, certFingerprint: fingerprint)
                case .needsUserConfirmation(let fingerprint):
                    scannerState.requestFingerprintConfirmation(payload: payload, fingerprint: fingerprint)
                case .failed(let message):
                    scannerState.fail(message)
                }
            }
        }
    }

    /// Connect over wss with the fingerprint pinned. Every QR pairing path
    /// goes through here with a non-nil fingerprint (from the payload or the
    /// trust-confirmed probe), so scanning can never fall back to plain ws://.
    private func connect(payload: PairingPayload, certFingerprint: String) {
        connectTask = Task {
            do {
                let stored = try await PairingFlow.connect(
                    payload: payload,
                    certFingerprint: certFingerprint,
                    connectionManager: session.connection
                )
                guard !Task.isCancelled else { return }
                if !isEmbedded { dismiss() }
                if let onPaired {
                    onPaired(stored)
                } else {
                    coordinator.onPaired(stored)
                }
            } catch {
                guard !Task.isCancelled else { return }
                scannerState.fail("Connection failed: \(error.localizedDescription)")
            }
        }
    }
}

private enum ScannerAvailability {
    case available
    case checking
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
            // VisionKit cannot relocate its native guidance. Keep scan instructions
            // in the SwiftUI overlay, below the description and outside the scan window.
            isGuidanceEnabled: false,
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
        private var deduplicator = QRScannerDeduplicator()
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
                reportUnavailableIfNeeded(for: scanner, operation: .scannerStart)
            }
        }

        func dataScanner(
            _: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems _: [RecognizedItem]
        ) {
            process(addedItems)
        }

        func dataScanner(
            _: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems _: [RecognizedItem]
        ) {
            process(updatedItems)
        }

        private func process(_ items: [RecognizedItem]) {
            let candidates = items.compactMap { item -> String? in
                guard case .barcode(let barcode) = item else { return nil }
                return barcode.payloadStringValue
            }
            guard let code = deduplicator.accept(candidates) else { return }
            onCodeScanned(code)

            // Reset after 3 seconds to allow re-scanning
            resetTask?.cancel()
            resetTask = Task { [weak self] in
                try? await Task.sleep(for: Constants.QRScanner.duplicateScanResetDelay)
                guard !Task.isCancelled,
                      let self,
                      deduplicator.expire(matching: code) else { return }
                guard isActive, let scanner else { return }
                scanner.stopScanning()
                startScanning(scanner)
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError _: DataScannerViewController.ScanningUnavailable
        ) {
            reportUnavailableIfNeeded(for: dataScanner)
        }

        func deactivate() {
            isActive = false
            scanner = nil
            resetTask?.cancel()
            resetTask = nil
        }

        private func reportUnavailableIfNeeded(
            for scanner: DataScannerViewController, operation: DiagnosticOperation = .scannerAvailability
        ) {
            guard isActive, !scanner.isScanning else { return }
            PairingDiagnostics.scanner(operation, failure: operation == .scannerStart ? .startFailed : .unavailable)
            isActive = false
            onUnavailable()
        }
    }
}
#endif
