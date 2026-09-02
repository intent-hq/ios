import Testing
@testable import Intent

/// The QR-scan and intent://pair deep-link paths share PairingFlow: a payload
/// fingerprint is pinned directly, a fingerprint-less payload goes through
/// the cert probe + user trust confirmation, and a failed probe aborts —
/// pairing never falls back to plain ws://.
struct PairingFlowTests {

    private func payload(fingerprint: String?) -> PairingPayload {
        PairingPayload(
            hosts: ["127.0.0.1"], port: 5181, token: "t",
            certFingerprint: fingerprint, tcAddress: nil)
    }

    @Test @MainActor func payloadFingerprintIsPinnedWithoutProbing() async {
        var probed = false
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: "ab:cd")
        ) { _, _ in
            probed = true
            return nil
        }
        #expect(resolution == .pinned("ab:cd"))
        #expect(!probed, "A payload fingerprint must be pinned without probing")
    }

    @Test @MainActor func fingerprintlessPayloadRequiresTrustConfirmation() async {
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: nil)
        ) { hosts, port in
            #expect(hosts == ["127.0.0.1"])
            #expect(port == 5181)
            return "12:34"
        }
        #expect(resolution == .needsUserConfirmation("12:34"))
    }

    @Test @MainActor func failedProbeAbortsInsteadOfConnectingUnpinned() async {
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: nil)
        ) { _, _ in nil }
        #expect(resolution == .failed(
            message: CertFingerprintProbe.noCertErrorMessage))
    }
}
