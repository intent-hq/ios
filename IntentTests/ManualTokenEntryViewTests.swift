import Foundation
import Testing
@testable import Intent

/// Regression coverage for the manual-connect TLS probe decision: manual
/// connects must always be pinned, so a probe that finds no certificate
/// aborts with an error instead of falling back to an unpinned plain-WS
/// connection.
struct ManualTokenEntryViewTests {

    @Test @MainActor func probedFingerprintLeadsToConfirmation() {
        let fingerprint = "ab:cd:ef:01"
        let outcome = ManualTokenEntryView.probeOutcome(forFingerprint: fingerprint)
        #expect(outcome == .confirmFingerprint(fingerprint))
    }

    @Test @MainActor func nilFingerprintAbortsInsteadOfConnectingUnpinned() {
        let outcome = ManualTokenEntryView.probeOutcome(forFingerprint: nil)
        #expect(outcome == .abort(message: ManualTokenEntryView.noCertErrorMessage))
    }

    @Test @MainActor func emptyFingerprintAbortsInsteadOfConnectingUnpinned() {
        let outcome = ManualTokenEntryView.probeOutcome(forFingerprint: "")
        #expect(outcome == .abort(message: ManualTokenEntryView.noCertErrorMessage))
    }

    @Test @MainActor func abortMessageIsUserActionable() {
        #expect(ManualTokenEntryView.noCertErrorMessage.contains("TLS certificate"))
    }
}
