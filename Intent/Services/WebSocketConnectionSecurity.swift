import CryptoKit
import Foundation
import os

extension WebSocketConnection {
    #if DEBUG
    /// Plaintext escape hatch for loopback-only test servers; app code never enables it.
    nonisolated static let allowsPlaintextLoopbackForTesting =
        OSAllocatedUnfairLock(initialState: false)
    #endif

    nonisolated static var plaintextLoopbackOverrideActive: Bool {
        #if DEBUG
        allowsPlaintextLoopbackForTesting.withLock { $0 }
        #else
        false
        #endif
    }

    nonisolated static func trustedPin(_ certFingerprint: String?) -> String? {
        guard let pin = certFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pin.isEmpty else { return nil }
        return pin
    }

    nonisolated static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    nonisolated static func transportScheme(
        host: String,
        certFingerprint: String?
    ) throws -> String {
        if trustedPin(certFingerprint) != nil { return "wss" }
        #if DEBUG
        if plaintextLoopbackOverrideActive, isLoopbackHost(host) { return "ws" }
        #endif
        throw WebSocketTransportError.missingCertificatePin(host: host)
    }

    nonisolated static func makeURL(
        host: String,
        port: Int,
        certFingerprint: String?
    ) throws -> URL {
        let scheme = try transportScheme(host: host, certFingerprint: certFingerprint)
        guard let url = URL(string: "\(scheme)://\(host):\(port)/ws") else {
            throw WebSocketTransportError.invalidURL(host: host)
        }
        return url
    }

    nonisolated static func additionalHeaders(token: String) -> [(name: String, value: String)] {
        [(name: "Authorization", value: "Bearer \(token)")]
    }

    /// SHA-256 fingerprint of a DER-encoded certificate, formatted as
    /// lowercase colon-separated hex — the normalization the pairing flow uses.
    nonisolated static func fingerprint(ofCertificate der: Data) -> String {
        SHA256.hash(data: der)
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")
    }

    /// Case-insensitive fingerprint comparison — the sole trust decision for
    /// pinned connections.
    nonisolated static func fingerprintMatches(_ received: String, pinned: String) -> Bool {
        received.lowercased() == pinned.lowercased()
    }
}
