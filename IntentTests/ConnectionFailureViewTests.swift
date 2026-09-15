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

    /// ios#251: a saved record refused for having no trusted pin lands on
    /// the re-pair path — no auto-retry (which would re-dial the same
    /// pin-less record), "Re-pair Device" offered, saved record kept.
    @Test func missingPinRefusalRoutesToCertPath() {
        let error = WebSocketTransportError.missingCertificatePin(host: "10.0.0.1")
        #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
    }

    @Test func genericFailuresDoNotRouteToCertPath() {
        #expect(!ConnectionFailureView.isCertificateMismatchMessage(
            "Connection to 192.168.1.42 timed out"))
        #expect(!ConnectionFailureView.isCertificateMismatchMessage(
            "The server at 192.168.1.42:5179 is not responding."))
    }

    // MARK: - Auto-retry decision

    /// ios#235: a failed Log Off (`.manualLogOff`) never auto-reconnects;
    /// certificate failures route to re-pairing; only an ordinary failure
    /// under `.automaticConnection` retries on its own.
    @Test func shouldAutoRetryOnlyForOrdinaryAutomaticFailures() {
        #expect(ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .automaticConnection, isCertMismatch: false))
        #expect(!ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .automaticConnection, isCertMismatch: true))
        #expect(!ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .manualLogOff, isCertMismatch: false))
        #expect(!ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .manualLogOff, isCertMismatch: true))
    }

    @Test func retryBackoffIsExponentialAndCapped() {
        #expect(ConnectionFailureView.retryBackoff(attempt: 1) == .seconds(2))
        #expect(ConnectionFailureView.retryBackoff(attempt: 2) == .seconds(4))
        #expect(ConnectionFailureView.retryBackoff(attempt: 4) == .seconds(16))
        #expect(ConnectionFailureView.retryBackoff(attempt: 5) == .seconds(30))
        #expect(ConnectionFailureView.retryBackoff(attempt: 10) == .seconds(30))
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
