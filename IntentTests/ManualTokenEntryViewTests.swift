import Foundation
import Security
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

    // MARK: - Trust fingerprint extraction (the capture path of the probe's
    // TLS verify block, factored so it is testable without a live handshake)

    /// Self-signed DER certificate fixture (CN=CertFingerprintProbe Test
    /// Fixture) with its independently computed SHA-256 fingerprint
    /// (openssl dgst -sha256 -c), pinning the normalization end to end.
    private static let fixtureCertDERBase64 = """
        MIIBrTCCAVOgAwIBAgIUR7S/oedy6Qg4laIDRfAbIuYBqn8wCgYIKoZIzj0EAwIw\
        LDEqMCgGA1UEAwwhQ2VydEZpbmdlcnByaW50UHJvYmUgVGVzdCBGaXh0dXJlMB4X\
        DTI2MDgyOTEwMTEyMloXDTM2MDgyNjEwMTEyMlowLDEqMCgGA1UEAwwhQ2VydEZp\
        bmdlcnByaW50UHJvYmUgVGVzdCBGaXh0dXJlMFkwEwYHKoZIzj0CAQYIKoZIzj0D\
        AQcDQgAEVkKimPx0hA3zbzxwyqiGHf0H49UX0KjPyUXVA+vr7f7mAxj2e95Ag40q\
        EfjVSlQ86fh6AKRVirbc8sBcc27OH6NTMFEwHQYDVR0OBBYEFKOd1uZkcxPWviCp\
        MGasqz4joZjIMB8GA1UdIwQYMBaAFKOd1uZkcxPWviCpMGasqz4joZjIMA8GA1Ud\
        EwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAO+/RKPbc1iCKK/jXutrkiI3\
        slELtPaJNU4NbTHFHa2nAiAdM9J2cpWId3aYi3to72sTXOinhpR8SsRaqppIuuWw\
        0A==
        """
    private static let fixtureCertFingerprint =
        "fb:3b:01:08:d8:20:77:6e:34:31:21:25:24:64:3e:95:91:bf:b4:4a:3d:80:cf:77:e5:a8:46:a0:48:90:eb:aa"

    private static func fixtureServerTrust() throws -> SecTrust {
        let der = try #require(Data(base64Encoded: fixtureCertDERBase64))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    @Test func trustFingerprintMatchesOpenSSLDigestOfLeafCertificate() throws {
        let trust = try Self.fixtureServerTrust()
        #expect(CertFingerprintProbe.fingerprint(fromServerTrust: trust) == Self.fixtureCertFingerprint)
    }

    @Test func trustFingerprintUsesSharedTransportNormalization() throws {
        let der = try #require(Data(base64Encoded: Self.fixtureCertDERBase64))
        let trust = try Self.fixtureServerTrust()
        #expect(CertFingerprintProbe.fingerprint(fromServerTrust: trust)
            == WebSocketConnection.fingerprint(ofCertificate: der))
    }
}
