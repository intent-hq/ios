import CryptoKit
import Foundation
@testable import Intent
import Testing

/// Contract checks against services/push-relay (README and test fixtures).
/// Known-answer values were produced with Node's crypto, as the relay uses it.
struct PushRelayContractTests {
    nonisolated private struct SoftwareSigner: RelaySigner {
        let key: P256.Signing.PrivateKey

        var publicKeyX963: Data { key.publicKey.x963Representation }

        func sign(_ message: Data) throws -> Data {
            try key.signature(for: message).rawRepresentation
        }
    }

    private final class BundleLocator {}

    private let signer: SoftwareSigner

    init() throws {
        // Private scalar 0x01…0x20.
        signer = SoftwareSigner(key: try P256.Signing.PrivateKey(rawRepresentation: Data(UInt8(1)...UInt8(32))))
    }

    @Test func contentStateFixtureDecodes() throws {
        let bundle = Bundle(for: BundleLocator.self)
        let url = try #require(
            bundle.url(forResource: "push-relay-content-state", withExtension: "json")
                ?? bundle.url(forResource: "push-relay-content-state", withExtension: "json", subdirectory: "Fixtures")
        )
        let state = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: Data(contentsOf: url))
        #expect(state.runningCount == 2)
        #expect(state.updatedAt == 1_800_000_000)
        #expect(state.rows.map(\.workspaceId) == ["w1", "w2"])
        #expect(state.rows[0].connectionId == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        #expect(state.rows[0].link?.agentId == "agent-123")
        #expect(state.rows[1].detail == nil)
        #expect(state.rows[1].link == nil)
    }

    @Test func publicKeyAndDeviceIdMatchRelayDerivation() {
        #expect(signer.publicKeyX963.count == 65)
        #expect(signer.publicKey == "BFFcPW6545a5BNP-yn9U_c0MwemXvzddylFa0KbDtANfRTa-OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q")
        #expect(signer.deviceId == "QmmIlDHjExlm_K9qRXFBlD7Sw1tbkXrmLLM5VG9SNVE")
    }

    @Test func bodyHashMatchesRelay() {
        #expect(RelayProof.bodyHash(Data()) == "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
        #expect(RelayProof.bodyHash(Data(#"{"pushToken":null}"#.utf8)) == "UOjGrMKGg9bKQHPo1q1aivLdgsLL1vdqCWJSzKPdqeo")
    }

    @Test func relaySignatureVerifiesWithRawRepresentation() throws {
        let input = "eyJhbGciOiJFUzI1NiIsInR5cCI6ImludGVudC1kZXZpY2Urand0In0.e30"
        let raw = try #require(Base64URL.decode("DGmW9Gg3OH7NaAdZJIwhYM1YzE3qxHI6tiHYrchoZksXJWbe04y9d3CRrJi411mIhs90PkoenYvHrg43adiFWg"))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(signer.key.publicKey.isValidSignature(signature, for: Data(input.utf8)))
    }

    @Test func proofBindsRequestAndVerifies() throws {
        let body = Data(#"{"pushToken":null}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let jws = try RelayProof.make(
            signer: signer,
            method: "PUT",
            path: "/v1/devices/\(signer.deviceId)/live-activity",
            body: body,
            now: now,
            jti: "0123456789abcdef0123"
        )
        let parts = jws.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        #expect(parts[0] == "eyJhbGciOiJFUzI1NiIsInR5cCI6ImludGVudC1kZXZpY2Urand0In0")

        let claims = try JSONDecoder().decode(RelayProof.Claims.self, from: try #require(Base64URL.decode(parts[1])))
        #expect(claims == RelayProof.Claims(
            sub: signer.deviceId,
            htm: "PUT",
            htu: "/v1/devices/\(signer.deviceId)/live-activity",
            bsh: "UOjGrMKGg9bKQHPo1q1aivLdgsLL1vdqCWJSzKPdqeo",
            iat: 1_800_000_123,
            jti: "0123456789abcdef0123"
        ))

        let raw = try #require(Base64URL.decode(parts[2]))
        #expect(raw.count == 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(signer.key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func generatedJTIFitsRelayBounds() {
        let jti = RelayProof.newJTI()
        #expect((16...128).contains(jti.count))
        #expect(jti != RelayProof.newJTI())
    }

    @Test func devicePatchOmitsUnsetFields() throws {
        let patch = RelayDeviceInfo(pushToken: "abcd")
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        #expect(Set(json.keys) == ["pushToken"])
    }
}
