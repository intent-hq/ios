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
}
