import SwiftUI
#if !os(visionOS)
@preconcurrency import AVFoundation
import Vision
import VisionKit
#endif

#if os(visionOS)
/// DataScannerViewController (VisionKit live camera scanning) is unavailable
/// on visionOS; keep the same API so call sites compile, and direct the user
/// to manual token entry.
struct QRScannerView: View {
    @Environment(\.dismiss) var dismiss
    /// Unused on visionOS: kept so call sites pass the same arguments as the
    /// iOS QRScannerView below.
    var onPaired: ((StoredConnection) -> Void)?

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
                        IntentIconButton(icon: .close, label: "Cancel") { dismiss() }
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
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var pendingPayload: PairingPayload?
    @State private var probedFingerprint: String?
    @State private var showFingerprintConfirmation = false
    @State private var scannerAvailability: ScannerAvailability = .checking
    @State private var errorAutoClearID: UUID?

    var body: some View {
        ZStack {
            scannerLayer
            QRScannerOverlay(
                showsGuide: scannerAvailability == .available,
                isValidating: isValidating,
                errorMessage: errorMessage
            ) {
                dismiss()
            }
        }
        .preferredColorScheme(.dark)
        .alert("Verify Server Identity", isPresented: $showFingerprintConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingPayload = nil
                isValidating = false
            }
            Button("Trust & Connect") { trustPendingFingerprint() }
        } message: {
            Text("The server's TLS certificate fingerprint is:\n\n\(probedFingerprint ?? "")\n\nDo you trust this server?")
        }
        .task { await prepareScanner() }
        .task(id: errorAutoClearID) { await clearErrorAfterDelay() }
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
        if let payload = pendingPayload, let fingerprint = probedFingerprint {
            pendingPayload = nil
            connect(payload: payload, certFingerprint: fingerprint)
        } else {
            pendingPayload = nil
            isValidating = false
        }
    }

    private func clearErrorAfterDelay() async {
        guard errorAutoClearID != nil else { return }
        do {
            try await Task.sleep(for: Constants.QRScanner.errorDisplayDuration)
        } catch {
            return
        }
        errorMessage = nil
        errorAutoClearID = nil
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
        guard !isValidating else { return }

        // Parse both pairing-URI dialects (canonical `fp=` and legacy
        // `certFingerprint=`); see PairingPayload.
        guard let payload = PairingPayload.parse(code) else {
            PairingDiagnostics.invalidInput()
            errorMessage = "Invalid QR code. Scan the code from Settings -> Mobile in the desktop app."
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
                    payload: payload,
                    certFingerprint: certFingerprint,
                    connectionManager: session.connection
                )
                dismiss()
                if let onPaired {
                    onPaired(stored)
                } else {
                    coordinator.onPaired(stored)
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
    case available
    case checking
    case unavailable
}

private struct QRScannerOverlay: View {
    let showsGuide: Bool
    let isValidating: Bool
    let errorMessage: String?
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsGuide { scanGuide }
            Button("Cancel", action: onCancel)
                .interFont(Constants.Typography.bodySEmphasized)
                .foregroundStyle(.black)
                .padding(.horizontal, Constants.QRScanner.cancelHorizontalPadding)
                .frame(minWidth: Constants.QRScanner.cancelWidth, minHeight: Constants.QRScanner.cancelHeight)
                .background(.white, in: .rect(cornerRadius: Constants.ConnectionSheet.fieldCornerRadius))
                .buttonStyle(IntentContentButtonStyle())
                .padding(.leading, Constants.QRScanner.horizontalInset)
                .padding(.top, Constants.QRScanner.cancelTopPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var scanGuide: some View {
        let geometry = QRScannerGeometry(
            horizontalInset: Constants.QRScanner.horizontalInset,
            verticalOffset: Constants.QRScanner.windowVerticalOffset
        )
        return ZStack {
            QRScannerMask(geometry: geometry, cornerRadius: Constants.QRScanner.windowCornerRadius)
                .fill(.black.opacity(Constants.QRScanner.dimmingOpacity), style: FillStyle(eoFill: true))
            QRScannerCorners(
                geometry: geometry,
                armLength: Constants.QRScanner.bracketArmLength,
                cornerRadius: Constants.QRScanner.windowCornerRadius
            )
            .stroke(.white, style: StrokeStyle(lineWidth: Constants.QRScanner.bracketWidth, lineCap: .round))
            QRScannerStatusLayout(geometry: geometry, topPadding: Constants.QRScanner.instructionTopPadding) {
                scannerStatus
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Constants.QRScanner.horizontalInset)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var scannerStatus: some View {
        VStack(spacing: Constants.QRScanner.statusSpacing) {
            HStack(spacing: Constants.QRScanner.statusSpacing) {
                if isValidating {
                    ProgressView().tint(.white)
                    Text("Connecting…")
                        .interFont(Constants.Typography.bodyXS)
                } else if let error = errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .interFont(Constants.Typography.bodyXS)
                } else {
                    Image(.scanHint)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Constants.QRScanner.hintIconSize, height: Constants.QRScanner.hintIconSize)
                        .accessibilityHidden(true)
                    Text("Find QR code in Settings -> Mobile")
                        .interFont(Constants.Typography.bodyXS)
                }
            }
            if !isValidating, errorMessage == nil {
                Text("Hold your device steady")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
    }
}

/// All guide elements derive their coordinates during layout, including the first frame.
nonisolated private struct QRScannerGeometry {
    let horizontalInset: CGFloat
    let verticalOffset: CGFloat

    func window(in rect: CGRect) -> CGRect {
        let side = max(0, min(rect.width - 2 * horizontalInset, rect.height / 2))
        return CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2 + verticalOffset,
            width: side,
            height: side
        )
    }
}

nonisolated private struct QRScannerMask: Shape {
    let geometry: QRScannerGeometry
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addPath(
            RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                .path(in: geometry.window(in: rect))
        )
        return path
    }
}

private struct QRScannerStatusLayout: Layout {
    let geometry: QRScannerGeometry
    let topPadding: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let window = geometry.window(in: bounds)
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: window.maxY + topPadding),
                anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }
}

nonisolated private struct QRScannerCorners: Shape {
    let geometry: QRScannerGeometry
    let armLength: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let window = geometry.window(in: rect)
        let arm = min(armLength, window.width / 2)
        let radius = min(cornerRadius, arm)
        var corner = Path()
        corner.move(to: CGPoint(x: arm, y: 0))
        corner.addArc(tangent1End: .zero, tangent2End: CGPoint(x: 0, y: arm), radius: radius)
        corner.addLine(to: CGPoint(x: 0, y: arm))
        var path = Path()
        for (scaleX, originX) in [(1.0, window.minX), (-1.0, window.maxX)] {
            for (scaleY, originY) in [(1.0, window.minY), (-1.0, window.maxY)] {
                path.addPath(corner, transform: CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: originX, ty: originY))
            }
        }
        return path
    }
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
                      lastScannedCode == code else { return }
                lastScannedCode = nil
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
