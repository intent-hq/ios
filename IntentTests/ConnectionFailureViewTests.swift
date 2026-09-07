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

    // MARK: - Auto-retry dial target (window model v2)

    private static func makeConnection(port: Int) -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"], port: port, name: "daemon-\(port)", pairedAt: Date()),
            token: "tok-\(port)")
    }

    @Test func autoRetryDialsWindowBoundRecordNotAnotherSaved() {
        // Two saved records; the window is bound to the second. Auto-retry
        // must resolve the bound record — never whichever one a global
        // pointer (e.g. the last-used pairing record) designates.
        let lastUsed = Self.makeConnection(port: 1)
        let bound = Self.makeConnection(port: 2)

        let result = ConnectionFailureView.autoRetryConnection(
            connections: [lastUsed, bound], windowConnectionID: bound.id)

        #expect(result?.id == bound.id)
    }

    @Test func autoRetryHasNoTargetWhenBoundRecordDeleted() {
        // The bound record vanished mid-failure (deleted/tombstoned):
        // nothing to dial — the view routes to pairing instead of dialing
        // a surviving record for a different backend.
        let survivor = Self.makeConnection(port: 1)

        let result = ConnectionFailureView.autoRetryConnection(
            connections: [survivor], windowConnectionID: UUID())

        #expect(result == nil)
    }

    @Test func autoRetryHasNoTargetInUnboundWindow() {
        let saved = Self.makeConnection(port: 1)

        #expect(ConnectionFailureView.autoRetryConnection(
            connections: [saved], windowConnectionID: nil) == nil)
    }
}
