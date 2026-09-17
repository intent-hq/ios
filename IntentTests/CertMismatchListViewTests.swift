import Foundation
@testable import Intent
import Testing

/// Display formatting for the passive per-host cert-mismatch list shown
/// while connecting/reconnecting and on the re-pair screen.
struct CertMismatchListViewTests {
    @Test func fullSha256FingerprintIsTruncatedToLeadingBytes() {
        let fingerprint = (0..<32).map { String(format: "%02x", $0) }
            .joined(separator: ":")
        let display = CertMismatchListView.displayFingerprint(fingerprint)
        #expect(display == "00:01:02:03:04:05:06:07…")
    }

    @Test func shortFingerprintPassesThroughUnchanged() {
        #expect(CertMismatchListView.displayFingerprint("ab:cd:ef") == "ab:cd:ef")
    }

    @Test func exactBoundaryFingerprintIsNotTruncated() {
        let eightBytes = "00:11:22:33:44:55:66:77"
        #expect(CertMismatchListView.displayFingerprint(eightBytes) == eightBytes)
    }

    @Test func customByteBudgetIsHonored() {
        let display = CertMismatchListView.displayFingerprint(
            "aa:bb:cc:dd:ee",
            maxBytes: 2
        )
        #expect(display == "aa:bb…")
    }
}
