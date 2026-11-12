#if os(iOS)
import CryptoKit
import Foundation
import Security

/// The phone's push relay identity: one P-256 key kept on this device only.
/// It lives in the Secure Enclave when there is one; the Keychain holds the
/// enclave's wrapped blob, or the software key on the Simulator.
nonisolated final class RelayDeviceKey: RelaySigner, @unchecked Sendable {
    nonisolated enum LoadError: Error {
        /// The Keychain is locked (before first unlock). Never replace the key
        /// then, or the relay would see a new device.
        case keychainUnavailable(OSStatus)
        case keyCreationFailed
    }

    nonisolated private enum Backing {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    nonisolated private enum Tag: UInt8 {
        case secureEnclave = 1
        case software = 2
    }

    private static let service = "dev.intentapp.ios.push-relay"
    private static let account = "device-key-v1"

    private let backing: Backing

    private init(_ backing: Backing) {
        self.backing = backing
    }

    var publicKeyX963: Data {
        switch backing {
        case .secureEnclave(let key): key.publicKey.x963Representation
        case .software(let key): key.publicKey.x963Representation
        }
    }

    func sign(_ message: Data) throws -> Data {
        switch backing {
        case .secureEnclave(let key): return try key.signature(for: message).rawRepresentation
        case .software(let key): return try key.signature(for: message).rawRepresentation
        }
    }

    /// Reads the stored key, creating and storing one only when none exists.
    static func loadOrCreate() throws -> RelayDeviceKey {
        switch read() {
        case .success(let blob):
            if let blob, let key = decode(blob) { return key }
            if blob != nil { delete() }
        case .failure(let error):
            throw error
        }
        let (key, blob) = try create()
        guard store(blob) else { throw LoadError.keyCreationFailed }
        return key
    }

    private static func create() throws -> (RelayDeviceKey, Data) {
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            if let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage,
                &error
            ), let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) {
                return (RelayDeviceKey(.secureEnclave(key)), Data([Tag.secureEnclave.rawValue]) + key.dataRepresentation)
            }
        }
        let key = P256.Signing.PrivateKey()
        return (RelayDeviceKey(.software(key)), Data([Tag.software.rawValue]) + key.rawRepresentation)
    }

    private static func decode(_ blob: Data) -> RelayDeviceKey? {
        guard let first = blob.first, let tag = Tag(rawValue: first) else { return nil }
        let body = blob.dropFirst()
        switch tag {
        case .secureEnclave:
            return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(body)))
                .map { RelayDeviceKey(.secureEnclave($0)) }
        case .software:
            return (try? P256.Signing.PrivateKey(rawRepresentation: body))
                .map { RelayDeviceKey(.software($0)) }
        }
    }

    // MARK: - Keychain

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func read() -> Result<Data?, LoadError> {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .success(result as? Data ?? Data())
        case errSecItemNotFound: return .success(nil)
        default: return .failure(.keychainUnavailable(status))
        }
    }

    private static func store(_ blob: Data) -> Bool {
        var query = baseQuery
        query[kSecValueData as String] = blob
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func delete() {
        _ = SecItemDelete(baseQuery as CFDictionary)
    }
}
#endif
