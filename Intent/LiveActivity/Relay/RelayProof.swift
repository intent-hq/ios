import CryptoKit
import Foundation

/// Signs push relay requests: an ES256 key whose public half identifies the device.
nonisolated protocol RelaySigner: Sendable {
    /// Uncompressed X9.63 P-256 public key (65 bytes).
    var publicKeyX963: Data { get }
    /// ECDSA P-256 / SHA-256 signature as raw r‖s (64 bytes).
    func sign(_ message: Data) throws -> Data
}

extension RelaySigner {
    nonisolated var publicKey: String { Base64URL.encode(publicKeyX963) }
    nonisolated var deviceId: String { Base64URL.encode(Data(SHA256.hash(data: publicKeyX963))) }
}

nonisolated enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let blockSize = 4
        base64 += String(repeating: "=", count: (blockSize - base64.count % blockSize) % blockSize)
        return Data(base64Encoded: base64)
    }
}

/// The `Authorization: IntentProof <JWS>` value from the relay contract
/// (services/push-relay/README.md): a compact JWS binding method, path, body
/// hash, time and a single-use id.
nonisolated enum RelayProof {
    static let scheme = "IntentProof"

    nonisolated struct Header: Codable, Equatable {
        let alg: String
        let typ: String

        static let device = Self(alg: "ES256", typ: "intent-device+jwt")
    }

    nonisolated struct Claims: Codable, Equatable {
        let sub: String
        let htm: String
        let htu: String
        let bsh: String
        let iat: Int
        let jti: String
    }

    private static let jtiByteCount = 18

    static func bodyHash(_ body: Data) -> String {
        Base64URL.encode(Data(SHA256.hash(data: body)))
    }

    static func newJTI() -> String {
        Base64URL.encode(Data((0..<jtiByteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func make(
        signer: any RelaySigner,
        method: String,
        path: String,
        body: Data,
        now: Date,
        jti: String = newJTI()
    ) throws -> String {
        let claims = Claims(
            sub: signer.deviceId,
            htm: method,
            htu: path,
            bsh: bodyHash(body),
            iat: Int(now.timeIntervalSince1970),
            jti: jti
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signingInput = Base64URL.encode(try encoder.encode(Header.device))
            + "." + Base64URL.encode(try encoder.encode(claims))
        let signature = try signer.sign(Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature)
    }
}
