import Foundation
@testable import Intent
import Testing

struct PairingPayloadTests {
    @Test func parsesCanonicalIntentdPairURI() {
        let payload = PairingPayload.parse(
            "intent://pair?v=1&host=192.168.1.10,10.0.0.5&port=5181&fp=aa:bb:cc:dd&token=abab1234"
        )
        #expect(payload != nil)
        #expect(payload?.hosts == ["192.168.1.10", "10.0.0.5"])
        #expect(payload?.port == 5181)
        #expect(payload?.token == "abab1234")
        #expect(payload?.certFingerprint == "aa:bb:cc:dd")
    }

    @Test func parsesFpParamAsFingerprint() {
        let payload = PairingPayload.parse(
            "intent://pair?host=10.0.0.7&port=5181&fp=de:ad:be:ef&token=tok"
        )
        #expect(payload?.certFingerprint == "de:ad:be:ef")
    }

    @Test func parsesLegacyCertFingerprintParam() {
        let payload = PairingPayload.parse(
            "intent://pair?token=tok&host=192.168.1.42&port=5181&path=/ws&certFingerprint=01:02:03"
        )
        #expect(payload != nil)
        #expect(payload?.hosts == ["192.168.1.42"])
        #expect(payload?.port == 5181)
        #expect(payload?.token == "tok")
        #expect(payload?.certFingerprint == "01:02:03")
    }

    @Test func fpWinsWhenBothFingerprintParamsPresent() {
        let payload = PairingPayload.parse(
            "intent://pair?host=h&port=1&token=t&certFingerprint=11:11&fp=22:22"
        )
        #expect(payload?.certFingerprint == "22:22")
    }

    @Test func parsesPayloadWithoutFingerprint() {
        let payload = PairingPayload.parse("intent://pair?host=h1&port=5181&token=t")
        #expect(payload != nil)
        #expect(payload?.certFingerprint == nil)
    }

    @Test func emptyFingerprintValuesNormalizeToNil() throws {
        let canonicalPayload = try #require(
            PairingPayload.parse("intent://pair?host=h&port=1&token=t&fp="),
            "An empty canonical fingerprint must not reject the pairing payload"
        )
        #expect(canonicalPayload.certFingerprint == nil)
        let legacyPayload = try #require(
            PairingPayload.parse("intent://pair?host=h&port=1&token=t&certFingerprint="),
            "An empty legacy fingerprint must not reject the pairing payload"
        )
        #expect(legacyPayload.certFingerprint == nil)
    }

    @Test func emptyFpFallsBackToNonEmptyLegacyFingerprint() {
        #expect(
            PairingPayload.parse("intent://pair?host=h&port=1&token=t&fp=&certFingerprint=11:11")?.certFingerprint
                == "11:11"
        )
    }

    @Test func toleratesVersionPathAndUnknownParams() {
        let payload = PairingPayload.parse(
            "intent://pair?v=1&path=/ws&future=x&host=h&port=5181&fp=aa&token=t"
        )
        #expect(payload != nil)
        #expect(payload?.certFingerprint == "aa")
    }

    @Test func parsesTcParamAsTunnelAddress() {
        let payload = PairingPayload.parse(
            "intent://pair?v=1&host=192.168.1.10&port=5181&fp=aa&token=t&tc=tc-abcdef123456"
        )
        #expect(payload?.tcAddress == "tc-abcdef123456")
    }

    @Test func absentTcParamIsToleratedAsNil() {
        let payload = PairingPayload.parse(
            "intent://pair?v=1&host=h&port=5181&fp=aa&token=t"
        )
        #expect(payload != nil)
        #expect(payload?.tcAddress == nil)
    }

    @Test func emptyTcParamNormalizesToNil() throws {
        let payload = try #require(
            PairingPayload.parse("intent://pair?host=h&port=1&token=t&tc="),
            "An empty tunnel address must not reject the pairing payload"
        )
        #expect(payload.tcAddress == nil)
    }

    @Test func splitsMultiHostList() {
        let payload = PairingPayload.parse(
            "intent://pair?host=192.168.1.10,10.0.0.5,172.16.0.2&port=5181&fp=aa&token=t"
        )
        #expect(payload?.hosts == ["192.168.1.10", "10.0.0.5", "172.16.0.2"])
    }

    @Test func decodesPercentEncodedValues() {
        let payload = PairingPayload.parse(
            "intent://pair?v=1&host=192.168.1.10%2C10.0.0.5&port=5181&fp=AA%3ABB%3ACC&token=ab%2Bcd%3D%3D"
        )
        #expect(payload?.hosts == ["192.168.1.10", "10.0.0.5"])
        #expect(payload?.certFingerprint == "AA:BB:CC")
        #expect(payload?.token == "ab+cd==")
    }

    @Test func rejectsMalformedPayloads() {
        #expect(PairingPayload.parse("https://pair?host=h&port=1&token=t") == nil)
        #expect(PairingPayload.parse("intent://other?host=h&port=1&token=t") == nil)
        #expect(PairingPayload.parse("intent://pair?port=1&token=t") == nil)
        #expect(PairingPayload.parse("intent://pair?host=h&token=t") == nil)
        #expect(PairingPayload.parse("intent://pair?host=h&port=1") == nil)
        #expect(PairingPayload.parse("intent://pair?host=h&port=abc&token=t") == nil)
        #expect(PairingPayload.parse("intent://pair?host=&port=1&token=t") == nil)
        #expect(PairingPayload.parse("not a uri") == nil)
    }

    @Test func truncatesLongTcAddressToTenCharsPlusEllipsis() {
        let shown = TcAddressDisplay.truncated("tc-abcdefghijklmnop")
        #expect(shown == "tc-abcdefg\u{2026}")
        #expect(shown.count == 11)
    }

    @Test func leavesExactlyTenCharTcAddressUnchanged() {
        #expect(TcAddressDisplay.truncated("tc-abcdefg") == "tc-abcdefg")
    }

    @Test func leavesShortTcAddressUnchanged() {
        #expect(TcAddressDisplay.truncated("tc-abc") == "tc-abc")
        #expect(TcAddressDisplay.truncated("").isEmpty)
    }

    @Test func truncatesElevenCharTcAddress() {
        #expect(TcAddressDisplay.truncated("tc-abcdefgh") == "tc-abcdefg\u{2026}")
    }

    @Test(arguments: ["token=", "token=t&token=other", "token=t&v=2", "token=t&port=0"])
    func rejectsAmbiguousPersonalCredentials(query: String) {
        #expect(PairingPayload.parse("intent://pair?host=test.invalid&port=443&\(query)") == nil)
    }
}
