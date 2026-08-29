import Foundation
import Testing
@testable import Intent

/// Regression coverage for the pairing TLS probe decision (shared by manual
/// entry and fingerprint-less QR payloads): pairing connections must always
/// be pinned, so a probe that finds no certificate aborts with an error
/// instead of falling back to an unpinned plain-WS connection.
struct ManualTokenEntryViewTests {

    @Test @MainActor func probedFingerprintLeadsToConfirmation() {
        let fingerprint = "ab:cd:ef:01"
        let outcome = CertFingerprintProbe.outcome(forFingerprint: fingerprint)
        #expect(outcome == .confirmFingerprint(fingerprint))
    }

    @Test @MainActor func nilFingerprintAbortsInsteadOfConnectingUnpinned() {
        let outcome = CertFingerprintProbe.outcome(forFingerprint: nil)
        #expect(outcome == .abort(message: CertFingerprintProbe.noCertErrorMessage))
    }

    @Test @MainActor func emptyFingerprintAbortsInsteadOfConnectingUnpinned() {
        let outcome = CertFingerprintProbe.outcome(forFingerprint: "")
        #expect(outcome == .abort(message: CertFingerprintProbe.noCertErrorMessage))
    }

    @Test @MainActor func abortMessageIsUserActionable() {
        #expect(CertFingerprintProbe.noCertErrorMessage.contains("TLS certificate"))
    }

    @Test func endpointPortAcceptsValidRange() {
        #expect(CertFingerprintProbe.endpointPort(1)?.rawValue == 1)
        #expect(CertFingerprintProbe.endpointPort(7550)?.rawValue == 7550)
        #expect(CertFingerprintProbe.endpointPort(65535)?.rawValue == 65535)
    }

    @Test func endpointPortRejectsOutOfRangeValues() {
        #expect(CertFingerprintProbe.endpointPort(0) == nil)
        #expect(CertFingerprintProbe.endpointPort(-1) == nil)
        #expect(CertFingerprintProbe.endpointPort(65536) == nil)
    }

    @Test func probeReturnsNilForInvalidPortWithoutConnecting() async {
        #expect(await CertFingerprintProbe.probe(host: "192.0.2.1", port: 0) == nil)
    }

    @Test func probeTimeoutMatchesPerHostWebSocketTimeout() {
        #expect(CertFingerprintProbe.probeTimeout == WebSocketConnection.connectTimeout)
    }
}
