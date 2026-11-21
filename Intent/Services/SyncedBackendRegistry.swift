import Foundation
import Security

// MARK: - Payload codec (v1 wire contract)

struct SyncedBackendRecord: Equatable, Sendable {
    var label: String
    var host: String
    var hosts: [String]
    var port: Int
    var fingerprint: String
    var hostname: String?
    var detectHosts: Bool
    var token: String
    var updatedAt: Double
    var deleted: Bool
    var deletedAt: Double?
    var tcAddress: String?
}

extension SyncedBackendRecord {
    var registryKey: String {
        let normalizedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalizedFingerprint.isEmpty { return "fp:\(normalizedFingerprint)" }
        return "addr:\(accountKey)"
    }

    var accountKey: String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedHost):\(port)"
    }

    func wins(over other: SyncedBackendRecord) -> Bool {
        if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
        if deleted != other.deleted { return deleted }
        return accountKey > other.accountKey
    }

    static let tombstoneTTLMs: Double = 30 * 24 * 60 * 60 * 1000 // swiftlint:disable:this no_magic_numbers
    private static let millisecondsPerSecond: Double = 1000

    func isExpiredTombstone(now: Date) -> Bool {
        deleted && (deletedAt ?? updatedAt) + Self.tombstoneTTLMs
            <= now.timeIntervalSince1970 * Self.millisecondsPerSecond
    }
}

enum SyncedBackendPayload {
    static let version = 1

    enum Parsed: Equatable {
        case invalid
        case newerVersion
        case record(SyncedBackendRecord)
    }

    static func parse(_ payload: String) -> Parsed {
        guard let data = payload.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else { return .invalid }
        guard let payloadVersion = number(object["v"])?.doubleValue else { return .invalid }
        if payloadVersion > Double(version) { return .newerVersion }
        guard let label = object["label"] as? String,
            let host = object["host"] as? String,
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let port = integer(object["port"]),
            let fingerprint = object["fingerprint"] as? String,
            let updatedAt = number(object["updatedAt"])?.doubleValue
        else { return .invalid }
        var record = SyncedBackendRecord(
            label: label,
            host: host,
            hosts: object["hosts"] as? [String] ?? [host],
            port: port,
            fingerprint: fingerprint,
            hostname: object["hostname"] as? String,
            detectHosts: {
                if case let .value(value) = bool(object["detectHosts"]) { return value }
                return true
            }(),
            token: object["token"] as? String ?? "",
            updatedAt: updatedAt,
            deleted: false,
            deletedAt: nil,
            tcAddress: tunnelAddress(object["tcAddress"])
        )
        if case .value(true) = bool(object["deleted"]) {
            record.deleted = true
            record.deletedAt = number(object["deletedAt"])?.doubleValue ?? updatedAt
            record.token = ""
        }
        return .record(record)
    }

    static func tunnelAddress(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> NSNumber? { // swiftlint:disable:this legacy_objc_type
        guard let value = value as? NSNumber, // swiftlint:disable:this legacy_objc_type
              CFGetTypeID(value) != CFBooleanGetTypeID()
        else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value) else { return nil }
        return Int(exactly: value.doubleValue)
    }

    private static func bool(_ value: Any?) -> AnyCodableBooleanMatch {
        guard let value = value as? NSNumber, // swiftlint:disable:this legacy_objc_type
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return .typeMismatch }
        return .value(value.boolValue)
    }
}

// MARK: - Keychain list seam

enum SyncedKeychainListOutcome {
    case failure(OSStatus)
    case notFound
    case rows([[String: Any]])
}

protocol SyncedKeychainListing {
    func list(matching query: [String: Any]) -> SyncedKeychainListOutcome
}

struct SecItemSyncedKeychain: SyncedKeychainListing {
    func list(matching query: [String: Any]) -> SyncedKeychainListOutcome {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failure(status) }
        guard let rows = result as? [[String: Any]] else {
            return .failure(errSecInternalError)
        }
        return .rows(rows)
    }
}

// MARK: - Registry

enum SyncedBackendRegistryList: Equatable {
    case available([SyncedBackendRecord])
    case unavailable(SyncedBackendRegistryUnavailability)
}

enum SyncedBackendRegistryUnavailability: Equatable {
    case accessGroupUnresolved
    case keychainError(OSStatus)
}

struct SyncedBackendRegistry {
    static let service = "com.cloudlands.intent.backends"
    static let sharedAccessGroupSuffix = "dev.intentapp.backends"

    var keychain: SyncedKeychainListing = SecItemSyncedKeychain()
    var accessGroup: String? = Self.resolveSharedAccessGroup()

    static func resolveSharedAccessGroup(bundle: Bundle = .main) -> String? {
        sharedAccessGroup(
            appIdentifierPrefix: bundle.object(forInfoDictionaryKey: "AppIdentifierPrefix")
                as? String
        )
    }

    static func sharedAccessGroup(appIdentifierPrefix: String?) -> String? {
        guard var prefix = appIdentifierPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prefix.isEmpty
        else { return nil }
        if !prefix.hasSuffix(".") { prefix += "." }
        return prefix + sharedAccessGroupSuffix
    }

    static func listQuery(accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
    }

    func listBackends(now: Date = Date()) -> SyncedBackendRegistryList {
        guard let accessGroup else { return .unavailable(.accessGroupUnresolved) }
        switch keychain.list(matching: Self.listQuery(accessGroup: accessGroup)) {
        case .failure(let status):
            return .unavailable(.keychainError(status))
        case .notFound:
            return .available([])
        case .rows(let rows):
            var newestByKey: [String: SyncedBackendRecord] = [:]
            var keyOrder: [String] = []
            for row in rows {
                guard let data = row[kSecValueData as String] as? Data,
                    let payload = String(data: data, encoding: .utf8),
                    case .record(let record) = SyncedBackendPayload.parse(payload),
                    !record.isExpiredTombstone(now: now)
                else { continue }
                let key = record.registryKey
                if let existing = newestByKey[key] {
                    if record.wins(over: existing) { newestByKey[key] = record }
                } else {
                    newestByKey[key] = record
                    keyOrder.append(key)
                }
            }
            return .available(keyOrder.compactMap { newestByKey[$0] })
        }
    }

    func listLiveBackends(now: Date = Date()) -> SyncedBackendRegistryList {
        switch listBackends(now: now) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let records):
            return .available(records.filter { !$0.deleted })
        }
    }
}
