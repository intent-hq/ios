import Foundation
import Testing
@testable import Intent

/// Routing of connection-failure messages into the certificate-mismatch
/// path (no auto-retry, "Re-pair Device" action, per-host mismatch list).
struct ConnectionFailureViewTests {

    @Test func aggregateRaceErrorRoutesToCertPath() {
        let error = WebSocketTransportError.certificateMismatches(mismatches: [
            HostCertMismatch(host: "h1", fingerprint: "aa:bb"),
            HostCertMismatch(host: "h2", fingerprint: "cc:dd"),
        ])
        #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
    }

    @Test func singleMismatchErrorRoutesToCertPath() {
        let error = WebSocketTransportError.certificateMismatch(
            host: "h1", fingerprint: "aa:bb")
        #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
    }

    @Test func repairPromptRoutesToCertPath() {
        #expect(ConnectionFailureView.isCertificateMismatchMessage(
            "Server certificate has changed. Please re-pair your device."))
    }

    @Test func genericFailuresDoNotRouteToCertPath() {
        #expect(!ConnectionFailureView.isCertificateMismatchMessage(
            "Connection to 192.168.1.42 timed out"))
        #expect(!ConnectionFailureView.isCertificateMismatchMessage(
            "The server at 192.168.1.42:5179 is not responding."))
    }
}
