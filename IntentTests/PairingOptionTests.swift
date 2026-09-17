@testable import Intent
import Testing

/// Tests for the platform-filtered pairing options: QR scanning requires a
/// camera, which visionOS does not expose to third-party apps, so it must be
/// excluded there and offered on iOS.
struct PairingOptionTests {
    @Test func excludesQRScanWithoutCameraScanning() {
        let options = PairingOption.available(
            showsSavedConnections: false,
            supportsCameraScanning: false
        )
        #expect(!options.contains(.qrScan))
        #expect(options == [.manualEntry])
    }

    @Test func offersQRScanFirstWithCameraScanning() {
        let options = PairingOption.available(
            showsSavedConnections: false,
            supportsCameraScanning: true
        )
        #expect(options == [.qrScan, .manualEntry])
    }

    @Test func appendsSavedConnectionsWhenRequested() {
        #expect(
            PairingOption.available(showsSavedConnections: true, supportsCameraScanning: true)
                == [.qrScan, .manualEntry, .savedConnections]
        )
        #expect(
            PairingOption.available(showsSavedConnections: true, supportsCameraScanning: false)
                == [.manualEntry, .savedConnections]
        )
    }

    @Test func platformDefaultMatchesBuildTarget() {
        #if os(visionOS)
        #expect(!PairingOption.platformSupportsCameraScanning)
        #expect(!PairingOption.available(showsSavedConnections: false).contains(.qrScan))
        #else
        #expect(PairingOption.platformSupportsCameraScanning)
        #expect(PairingOption.available(showsSavedConnections: false).contains(.qrScan))
        #endif
    }
}
