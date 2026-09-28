import CryptoKit
import Foundation
import os

extension WebSocketConnection {
    nonisolated enum Endpoint: Sendable {
        case rpc
        case tunnel

        var path: String { self == .rpc ? "/ws" : "/tunnel" }
        var maximumMessageSize: Int {
            self == .rpc ? WebSocketConnection.maximumMessageSize : BrowserTunnelFrame.maximumMessageSize
        }
    }

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
        certFingerprint: String?,
        endpoint: Endpoint = .rpc
    ) throws -> URL {
        let scheme = try transportScheme(host: host, certFingerprint: certFingerprint)
        guard (1...Int(UInt16.max)).contains(port), !host.isEmpty,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@")
                .union(.whitespacesAndNewlines)) == nil else {
            throw WebSocketTransportError.invalidURL(host: host)
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port
        components.path = endpoint.path
        guard let url = components.url else {
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

    /// Compare validated SHA-256 bytes, accepting both supported spellings.
    nonisolated static func fingerprintMatches(_ received: String, pinned: String) -> Bool {
        guard let received = try? InvitedSyncKey.fingerprint(received),
              let pinned = try? InvitedSyncKey.fingerprint(pinned) else { return false }
        return received == pinned
    }
}
