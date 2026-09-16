import Foundation
import Security

/// Read-only view of the iCloud-synced backend registry written by the
/// desktop app's keychain helper (cloudlands-fe `keychain-sync.ts` +
/// `sync-helper.swift`): ONE generic-password item per backend under the
/// fixed service `com.cloudlands.intent.backends` in the cross-app shared
/// access group, keyed by the normalized `host:port` account, carrying a
/// versioned JSON payload. This layer only LISTS records — no writes, no
/// reconcile — and is fail-soft: any SecItem failure (including entitlement
/// rejection) surfaces as `.unavailable`, never as "no items".

// MARK: - Payload codec (v1 wire contract)

/// One synced backend record — the decoded keychain payload. Tombstones keep
/// the identity fields but always carry an empty `token`.
///
/// NOT `Codable` on purpose: the wire contract lives in
/// `SyncedBackendPayload.parse` (typeof-faithful, versioned, defaulting) —
/// a synthesized encoder/decoder would emit no `v` and skip every contract
/// rule, so it must never exist as a tempting round-trip path.
struct SyncedBackendRecord: Equatable, Sendable {
    var label: String
    /// Primary remote host/IP (identity, with `port`).
    var host: String
    /// Candidate hosts (primary first).
    var hosts: [String]
    var port: Int
    var fingerprint: String
    var hostname: String?
    var detectHosts: Bool
    /// Bearer token; always `""` on tombstones.
    var token: String
    /// Last-writer-wins conflict clock, ms since epoch.
    var updatedAt: Double
    /// Tombstone marker: the backend was forgotten on some machine.
    var deleted: Bool
    /// When the tombstone was written (ms since epoch).
    var deletedAt: Double?
}

extension SyncedBackendRecord {
    /// Canonical dedupe identity: normalized cert fingerprint (trimmed,
    /// uppercased) when present, else the normalized `host:port` (host
    /// trimmed + lowercased) — same normalization as the desktop reconcile.
    /// Prefixed so a colon-separated fingerprint can never collide with a
    /// `host:port` key.
    var registryKey: String {
        let fp = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !fp.isEmpty { return "fp:\(fp)" }
        return "addr:\(accountKey)"
    }

    /// Normalized `host:port` account key (host trimmed + lowercased) —
    /// mirrors the fe's `accountKeyFor`. Used as the deterministic
    /// live/live tie-breaker, matching reconcile's `account > match.account`.
    var accountKey: String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedHost):\(port)"
    }

    /// Whether `self` beats `other` for the same `registryKey`, mirroring
    /// the fe reconcile's conflict rules so every device converges on the
    /// same survivor regardless of keychain row order: strictly newer
    /// `updatedAt` wins; on an equal clock a tombstone beats a live record
    /// (an address change must not dodge a delete); an equal-clock
    /// live/live (or tombstone/tombstone) tie breaks by the larger
    /// normalized account key.
    func wins(over other: SyncedBackendRecord) -> Bool {
        if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
        if deleted != other.deleted { return deleted }
        return accountKey > other.accountKey
    }

    /// Tombstone TTL, mirroring the desktop reconcile's `TOMBSTONE_TTL_MS`
    /// (~30 days): the desktop purges expired tombstones from the keychain,
    /// so a straggler item the purge has not reached yet must not still act
    /// as a delete here.
    static let tombstoneTTLMs: Double = 30 * 24 * 60 * 60 * 1000

    /// Whether this record is a tombstone past its TTL (`deletedAt`,
    /// falling back to `updatedAt`, anchors the TTL — same as the fe's
    /// `isExpiredTombstone`).
    func isExpiredTombstone(now: Date) -> Bool {
        deleted && (deletedAt ?? updatedAt) + Self.tombstoneTTLMs <= now.timeIntervalSince1970 * 1000
    }
}

/// Parser for the versioned keychain payload, mirroring the desktop
/// `parsePayload` rules exactly: unknown fields tolerated, items written by
/// a NEWER app version are reported (and skipped by the registry) rather
/// than misparsed, tombstone tokens are always scrubbed. Never throws.
enum SyncedBackendPayload {
    /// Payload schema version this app understands
    /// (mirrors `KEYCHAIN_PAYLOAD_VERSION` in cloudlands-fe).
    static let version = 1

    enum Parsed: Equatable {
        case record(SyncedBackendRecord)
        case newerVersion
        case invalid
    }

    static func parse(_ payload: String) -> Parsed {
        guard let data = payload.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else { return .invalid }
        guard let v = number(object["v"])?.doubleValue else { return .invalid }
        if v > Double(version) { return .newerVersion }
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
            detectHosts: bool(object["detectHosts"]) ?? true,
            token: object["token"] as? String ?? "",
            updatedAt: updatedAt,
            deleted: false,
            deletedAt: nil
        )
        if bool(object["deleted"]) == true {
            record.deleted = true
            record.deletedAt = number(object["deletedAt"])?.doubleValue ?? updatedAt
            record.token = ""
        }
        return .record(record)
    }

    /// JSON number (never a JSON bool — JSONSerialization bridges both to
    /// NSNumber; the wire contract's `typeof x === "number"` must reject
    /// booleans). Compared as Double: the fe compares `v` numerically, so
    /// e.g. `v: 1.5` must count as newer than 1, never truncate to 1.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID()
        else { return nil }
        return value
    }

    /// JSON number that is exactly an integer. A fractional `port` is
    /// rejected as invalid rather than silently truncated (the fe would key
    /// the account by the literal number, so truncation misstates identity).
    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value) else { return nil }
        return Int(exactly: value.doubleValue)
    }

    /// JSON bool (never a JSON number).
    private static func bool(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return value.boolValue
    }
}

// MARK: - Keychain list seam

/// Outcome of one raw keychain list query. `notFound` (errSecItemNotFound)
/// is a SUCCESSFUL empty read; every other failure means "keychain state
/// unknown" and must never be treated as "no items".
enum SyncedKeychainListOutcome {
    case rows([[String: Any]])
    case notFound
    case failure(OSStatus)
}

/// Abstraction over `SecItemCopyMatching` list queries so tests can run
/// hermetically (SecItem calls fail in headless CI simulators) and assert
/// the exact query attributes.
protocol SyncedKeychainListing {
    func list(matching query: [String: Any]) -> SyncedKeychainListOutcome
}

/// Production backend over the Security framework.
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

/// Result of one registry read: `available` (possibly empty) is a
/// trustworthy listing; `unavailable` means the keychain could not be read
/// (missing entitlement, locked keychain, any SecItem error) and existing
/// knowledge should be kept as-is.
enum SyncedBackendRegistryList: Equatable {
    case available([SyncedBackendRecord])
    case unavailable(SyncedBackendRegistryUnavailability)
}

enum SyncedBackendRegistryUnavailability: Equatable {
    /// The team-prefixed shared access group could not be resolved
    /// (AppIdentifierPrefix missing from Info.plist).
    case accessGroupUnresolved
    /// SecItemCopyMatching failed (includes errSecMissingEntitlement /
    /// errSecNotAvailable on builds whose profile lacks the shared group).
    case keychainError(OSStatus)
}

/// Reader over the shared-group backend registry. Production use:
/// `SyncedBackendRegistry().listLiveBackends()`. Tests inject the seam and
/// an explicit access group.
struct SyncedBackendRegistry {
    /// Fixed service for synced backend items (mirrors cloudlands-fe).
    static let service = "com.cloudlands.intent.backends"
    /// Cross-app shared access group suffix; the full group is
    /// TEAMID-prefixed, e.g. "ABCDE12345.dev.intentapp.backends".
    static let sharedAccessGroupSuffix = "dev.intentapp.backends"

    var keychain: SyncedKeychainListing = SecItemSyncedKeychain()
    var accessGroup: String? = SyncedBackendRegistry.resolveSharedAccessGroup()

    /// Team-prefixed shared access group. iOS has no public entitlement
    /// introspection (the Mac helper uses SecTaskCopyValueForEntitlement),
    /// so the team prefix comes from Info.plist's `AppIdentifierPrefix`
    /// key, which the build expands from $(AppIdentifierPrefix).
    static func resolveSharedAccessGroup(bundle: Bundle = .main) -> String? {
        sharedAccessGroup(
            appIdentifierPrefix: bundle.object(forInfoDictionaryKey: "AppIdentifierPrefix")
                as? String)
    }

    /// Pure assembly: "TEAMID." prefix + group suffix, nil when the prefix
    /// is missing/blank.
    static func sharedAccessGroup(appIdentifierPrefix: String?) -> String? {
        guard var prefix = appIdentifierPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prefix.isEmpty
        else { return nil }
        if !prefix.hasSuffix(".") { prefix += "." }
        return prefix + sharedAccessGroupSuffix
    }

    /// List query mirroring the desktop helper's `baseQuery` + list
    /// attributes, scoped to the shared access group. Items are only ever
    /// written with kSecAttrSynchronizable = true; matching "any" is for
    /// robustness. iOS never writes these records, so it sets no
    /// accessibility class here — see the credential policy on
    /// `SecItemKeychainStorage` (ios#263).
    static func listQuery(accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
    }

    /// All key-winning records: malformed, newer-version and EXPIRED
    /// TOMBSTONE items (see `isExpiredTombstone`) are skipped, and records
    /// sharing a `registryKey` collapse to a single winner (LWW by
    /// `updatedAt` with the fe reconcile's deterministic tie rules — see
    /// `wins(over:)` — so a machine whose address changed never appears
    /// twice and row order never changes the outcome). INCLUDES winning
    /// unexpired tombstones — the merge into saved connections must act on
    /// them.
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

    /// The live records in the registry: `listBackends()` minus tombstones
    /// (a tombstone that wins its key hides the older live copies).
    func listLiveBackends(now: Date = Date()) -> SyncedBackendRegistryList {
        switch listBackends(now: now) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let records):
            return .available(records.filter { !$0.deleted })
        }
    }
}
