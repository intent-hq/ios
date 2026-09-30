import CryptoKit
import Foundation

/// §5.49 byte encoding. Swift String equality normalizes Unicode, so identity
/// and set operations here deliberately operate on UTF-8 bytes instead.
nonisolated enum InvitedSyncKey {
    enum Invalid: Error { case input }

    static let sessionPrefix = "invited-v2-s:"
    static let removalPrefix = "invited-v2-r:"
    private static let pinBytes = 32
    private static let hexWidth = 2

    static func fingerprint(_ value: String) throws -> String {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == pinBytes && parts.allSatisfy({ $0.utf8.count == hexWidth }) else { throw Invalid.input }
        let hex = parts.joined().lowercased()
        guard hex.utf8.count == pinBytes * hexWidth, hex.utf8.allSatisfy({ asciiHex.contains($0) }) else { throw Invalid.input }
        return hex
    }

    static func sameFingerprint(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let first = try? fingerprint(lhs), let second = try? fingerprint(rhs) else { return false }
        return first == second
    }

    private static let asciiHex = Set("0123456789abcdef".utf8)

    static func sorted(_ values: [String]) -> [String] {
        Set(values.map { Data($0.utf8) }).sorted { $0.lexicographicallyPrecedes($1) }.compactMap { String(data: $0, encoding: .utf8) }
    }

    static func session(fingerprint: String, principalId: String) throws -> String {
        let bytes = try identity(fingerprint, principalId)
        return sessionPrefix + digest(Data("intent.invited-sync/v2/session\0".utf8) + bytes)
    }

    static func removal(fingerprint: String, principalId: String, removalId: String, removedThrough: Double, legacyAccounts: [String]) throws -> String {
        guard let uuid = UUID(uuidString: removalId), uuid.uuidString.lowercased() == removalId,
              removalId.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil,
              ConnectionPrincipal.validClock(removedThrough), removedThrough > 0,
              legacyAccounts.map({ Data($0.utf8) }) == sorted(legacyAccounts).map({ Data($0.utf8) }) else { throw Invalid.input }
        var bytes = try identity(fingerprint, principalId)
        bytes += hexBytes(removalId.replacingOccurrences(of: "-", with: ""))
        bytes += integer(UInt64(removedThrough))
        guard let count = UInt32(exactly: legacyAccounts.count) else { throw Invalid.input }
        bytes += integer(count)
        for alias in legacyAccounts { bytes += try lengthPrefixed(alias) }
        return removalPrefix + digest(Data("intent.invited-sync/v2/removal\0".utf8) + bytes)
    }

    private static func identity(_ pin: String, _ principal: String) throws -> Data {
        try hexBytes(fingerprint(pin)) + lengthPrefixed(principal)
    }

    private static func lengthPrefixed(_ value: String) throws -> Data {
        guard !value.isEmpty, let count = UInt32(exactly: value.utf8.count) else { throw Invalid.input }
        return integer(count) + Data(value.utf8)
    }

    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func hexBytes(_ hex: String) -> Data {
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: hexWidth)
            if let byte = UInt8(hex[index..<end], radix: 16) { bytes.append(byte) } // swiftlint:disable:this no_magic_numbers
            index = end
        }
        return bytes
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
