import Foundation
@testable import Intent
import Testing

/// Regression coverage for intent-hq/monorepo#3014: the QR pairing parser
/// must understand BOTH pairing-URI dialects — the canonical daemon payload
/// (`intentd pair` / pairing.getInfo, `fp=` fingerprint) and the legacy
/// desktop-app payload (`certFingerprint=`) — and must never drop the
/// fingerprint of a canonical payload (which previously downgraded the
/// connection to plain ws:// against the TLS-only WSS listener).
struct PairingPayloadTests {
    // MARK: - Canonical daemon dialect (intentd pair)

    /// Exact URI shape documented in docs/protocol/05-method-catalog.md for
    /// pairing.getInfo — the payload `intentd pair` renders as a QR code.
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

    // MARK: - Legacy desktop dialect

    @Test func parsesLegacyCertFingerprintParam() {
        let payload = PairingPayload.parse(
            "intent://pair?token=tok&host=192.168.1.42&port=5180&path=/ws&certFingerprint=01:02:03"
        )
        #expect(payload != nil)
        #expect(payload?.hosts == ["192.168.1.42"])
        #expect(payload?.port == 5180)
        #expect(payload?.token == "tok")
        #expect(payload?.certFingerprint == "01:02:03")
    }

    // MARK: - Precedence: fp= (canonical) wins over certFingerprint= (legacy)

    @Test func fpWinsWhenBothFingerprintParamsPresent() {
        let payload = PairingPayload.parse(
            "intent://pair?host=h&port=1&token=t&certFingerprint=11:11&fp=22:22"
        )
        #expect(payload?.certFingerprint == "22:22")
    }

    // MARK: - No fingerprint

    /// A payload without any fingerprint still parses (the caller must then
    /// probe the server cert instead of downgrading to plain ws://).
    @Test func parsesPayloadWithoutFingerprint() {
        let payload = PairingPayload.parse("intent://pair?host=h1&port=5180&token=t")
        #expect(payload != nil)
        #expect(payload?.certFingerprint == nil)
    }

    /// An empty fingerprint value is normalized to nil so the caller takes
    /// the probe path instead of pinning an empty string.
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

    /// Precedence is "first non-empty wins, canonical fp= first": an empty
    /// fp= falls back to a non-empty legacy certFingerprint= rather than
    /// normalizing the whole result to nil.
    @Test func emptyFpFallsBackToNonEmptyLegacyFingerprint() {
        #expect(
            PairingPayload.parse("intent://pair?host=h&port=1&token=t&fp=&certFingerprint=11:11")?.certFingerprint
                == "11:11"
        )
    }

    // MARK: - Tolerated / ignored params

    @Test func toleratesVersionPathAndUnknownParams() {
        let payload = PairingPayload.parse(
            "intent://pair?v=1&path=/ws&future=x&host=h&port=5181&fp=aa&token=t"
        )
        #expect(payload != nil)
        #expect(payload?.certFingerprint == "aa")
    }

    // MARK: - Tailcat tunnel address (tc=)

    /// The daemon appends `tc=` only when its tunnel is running (the exact
    /// URI shape from crates/intent-transport pairing.rs).
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

    // MARK: - Multi-host list

    @Test func splitsMultiHostList() {
        let payload = PairingPayload.parse(
            "intent://pair?host=192.168.1.10,10.0.0.5,172.16.0.2&port=5181&fp=aa&token=t"
        )
        #expect(payload?.hosts == ["192.168.1.10", "10.0.0.5", "172.16.0.2"])
    }

    // MARK: - Percent-encoded values

    @Test func decodesPercentEncodedValues() {
        let payload = PairingPayload.parse(
            "intent://pair?v=1&host=192.168.1.10%2C10.0.0.5&port=5181&fp=AA%3ABB%3ACC&token=ab%2Bcd%3D%3D"
        )
        #expect(payload?.hosts == ["192.168.1.10", "10.0.0.5"])
        #expect(payload?.certFingerprint == "AA:BB:CC")
        #expect(payload?.token == "ab+cd==")
    }

    // MARK: - Malformed payloads

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

    // MARK: - Display truncation

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
}
