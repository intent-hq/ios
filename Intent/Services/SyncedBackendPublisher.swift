import Foundation
import Security

/// Injectable Security seam. Duplicate adds are retried from a fresh read;
/// they must never fall through to an unconditional overwrite.
protocol SyncedKeychainWriting: SyncedKeychainListing {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(matching query: [String: Any], attributes: [String: Any]) -> OSStatus
}

extension SecItemSyncedKeychain: SyncedKeychainWriting {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(matching query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

/// Publishes only durably saved local edits. Uses the raw shared dictionary
/// as the base so desktop-owned and future v1 fields survive a re-pair.
/// The shared registry remains LWW; iCloud supplies no cross-device CAS.
struct SyncedBackendPublisher {
    enum Outcome: Equatable {
        case published
        case retry
        case superseded(SyncedBackendRecord)
    }

    let keychain: any SyncedKeychainWriting
    let accessGroup: String?
    var now: () -> Date = Date.init

    private static let millisecondsPerSecond: Double = 1000

    /// Only the app's shared persistence opts into real publication. Test
    /// managers must inject their writer; demo and preview stores stay local.
    static func production() -> Self? {
        guard !DemoMode.isEnabled,
              NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
        else { return nil }
        return Self(keychain: SecItemSyncedKeychain(), accessGroup: SyncedBackendRegistry.resolveSharedAccessGroup())
    }

    /// A deliberate pairing may supersede a removal already observed at the
    /// time of that action. Clock skew and same-millisecond re-pairs cannot
    /// make that edit older than its known predecessor. A retry never calls
    /// this: it uses the clock saved atomically with the new token.
    func pairingClock(for connection: StoredConnection) -> Double {
        var clock = max(
            floor(now().timeIntervalSince1970 * Self.millisecondsPerSecond),
            max(connection.syncUpdatedAt ?? 0, connection.pendingSyncUpdatedAt ?? 0) + 1
        )
        if let target = target(for: connection), let rows = readRows() {
            for entry in rows.compactMap(Entry.init) where matches(entry, connection: connection, target: target) {
                clock = max(clock, entry.record.updatedAt + 1)
            }
        }
        return clock
    }

    /// One bounded attempt. Failures keep the pending edit for a later
    /// foreground pass, including across process restarts.
    func publish(_ connection: StoredConnection) -> Outcome {
        guard let clock = connection.pendingSyncUpdatedAt,
              let target = target(for: connection),
              let rows = readRows()
        else { return .retry }
        let entries = rows.compactMap(Entry.init)
        let winner = self.winner(in: entries, connection: connection, target: target)
        // Include expired tombstones here: an old local pairing must not
        // revive a deletion merely because its reader-side TTL elapsed.
        if let winner, winner.record.updatedAt >= clock {
            return acknowledges(connection, record: winner.record, clock: clock)
                ? .published : .superseded(winner.record)
        }
        let host = winner?.record.port == connection.server.port ? winner?.record.host ?? target.host : target.host
        let account = Self.account(host: host, port: connection.server.port)
        // Freeze unreadable/newer-schema rows for this identity, and never
        // replace a different certificate reusing the same host:port.
        guard !rows.contains(where: { blocks($0, connection: connection, accounts: [target.account, account]) })
        else { return .retry }
        guard let payload = payload(connection, host: host, winner: winner, clock: clock) else { return .retry }
        return write(payload, account: account, rows: rows, exists: entries.contains { $0.account == account })
    }

    /// Automatic route observations patch a live row only. They cannot add a
    /// missing/deleted backend or restamp stale credentials over newer edits.
    func publishRoutes(_ connection: StoredConnection) -> Outcome {
        guard let pending = connection.pendingRoutePublication,
              let target = target(for: connection), let rows = readRows(),
              let winner = self.winner(in: rows.compactMap(Entry.init), connection: connection, target: target)
        else { return .retry }
        guard !winner.record.deleted else { return .superseded(winner.record) }
        guard !rows.contains(where: { blocks($0, connection: connection, accounts: [target.account, winner.account]) })
        else { return .retry }
        if let desired = pending.tcAddress, let remote = winner.record.tcAddress,
           remote != desired, remote != pending.previousTcAddress {
            return .superseded(winner.record)
        }
        let hosts = PersistenceManager.mergeHostLists(existing: winner.record.hosts, incoming: pending.hosts)
        let route = pending.tcAddress ?? winner.record.tcAddress
        if hosts == winner.record.hosts, route == winner.record.tcAddress { return .published }
        var object = winner.object
        object["hosts"] = hosts
        if let route { object["tcAddress"] = route }
        object["updatedAt"] = max(pending.updatedAt, winner.record.updatedAt + 1)
        guard let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return .retry }
        return write(payload, account: winner.account, rows: rows, exists: true)
    }

    func routeClock(for connection: StoredConnection) -> Double {
        max(
            floor(now().timeIntervalSince1970 * Self.millisecondsPerSecond),
            max(connection.syncUpdatedAt ?? 0, connection.pendingRoutePublication?.updatedAt ?? 0) + 1
        )
    }

    private func winner(in entries: [Entry], connection: StoredConnection, target: Target) -> Entry? {
        entries
            .filter { matches($0, connection: connection, target: target) }
            .reduce(nil as Entry?) { winner, entry in
                guard let winner else { return entry }
                return entry.record.wins(over: winner.record) ? entry : winner
            }
    }

    private func write(_ payload: Data, account: String, rows: [[String: Any]], exists: Bool) -> Outcome {
        guard let accessGroup else { return .retry }
        let query = Self.itemQuery(account: account, accessGroup: accessGroup)
        // Re-read immediately before mutation to catch local concurrent
        // writers and preserve edits that landed during preparation.
        guard let freshRows = readRows(), Self.sameRows(rows, freshRows) else { return .retry }
        let status: OSStatus
        if exists {
            status = keychain.update(matching: query, attributes: [kSecValueData as String: payload])
        } else {
            var attributes = query
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecValueData as String] = payload
            status = keychain.add(attributes)
        }
        return status == errSecSuccess ? .published : .retry
    }

    /// An equal clock alone is not proof that this device wrote the row.
    /// Only equivalent connection fields acknowledge a failed local save;
    /// a competing edit must still reach the ordinary importer/live cache.
    private func acknowledges(_ connection: StoredConnection, record: SyncedBackendRecord, clock: Double) -> Bool {
        record.updatedAt == clock && !record.deleted
            && record.token == connection.token
            && record.label == connection.displayName
            && record.port == connection.server.port
            && record.accountKey == target(for: connection)?.account
            && record.hosts == connection.server.hosts
            && SyncedBackendConnectionMerge.normalizeFingerprint(record.fingerprint)
                == SyncedBackendConnectionMerge.normalizeFingerprint(connection.server.certFingerprint)
            && record.tcAddress == SyncedBackendPayload.tunnelAddress(connection.server.tcAddress)
    }

    private struct Target {
        var host: String
        var account: String
    }

    private struct Entry {
        var account: String
        var object: [String: Any]
        var record: SyncedBackendRecord

        init?(_ row: [String: Any]) {
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = String(data: data, encoding: .utf8),
                  case .record(let record) = SyncedBackendPayload.parse(text),
                  record.accountKey == account
            else { return nil }
            self.account = account
            self.object = object
            self.record = record
        }
    }

    private func target(for connection: StoredConnection) -> Target? {
        guard !connection.token.isEmpty,
              !SyncedBackendConnectionMerge.normalizeFingerprint(connection.server.certFingerprint).isEmpty,
              let host = connection.server.hosts.compactMap(SyncedBackendConnectionMerge.usableHost).first
                ?? SyncedBackendPayload.tunnelAddress(connection.server.tcAddress)
        else { return nil }
        return Target(host: host, account: Self.account(host: host, port: connection.server.port))
    }

    private static func account(host: String, port: Int) -> String {
        "\(SyncedBackendConnectionMerge.normalizeHost(host)):\(port)"
    }

    private func matches(_ entry: Entry, connection: StoredConnection, target: Target) -> Bool {
        let fingerprint = SyncedBackendConnectionMerge.normalizeFingerprint(entry.record.fingerprint)
        return fingerprint == SyncedBackendConnectionMerge.normalizeFingerprint(connection.server.certFingerprint)
            || fingerprint.isEmpty && entry.account == target.account
    }

    private func blocks(_ row: [String: Any], connection: StoredConnection, accounts: [String]) -> Bool {
        let account = row[kSecAttrAccount as String] as? String ?? ""
        let data = row[kSecValueData as String] as? Data
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let fingerprint = SyncedBackendConnectionMerge.normalizeFingerprint(object?["fingerprint"] as? String)
        let localFingerprint = SyncedBackendConnectionMerge.normalizeFingerprint(connection.server.certFingerprint)
        guard accounts.contains(account) || fingerprint == localFingerprint else { return false }
        guard let entry = Entry(row) else { return true }
        return !fingerprint.isEmpty && fingerprint != localFingerprint
            || entry.record.accountKey != account
    }

    private func payload(_ connection: StoredConnection, host: String, winner: Entry?, clock: Double) -> Data? {
        var object = winner?.object ?? [
            "v": SyncedBackendPayload.version,
            "hostname": NSNull(),
            "detectHosts": true
        ]
        object["label"] = connection.displayName
        object["host"] = host
        object["hosts"] = PersistenceManager.mergeHostLists(
            existing: connection.server.hosts,
            incoming: winner?.record.hosts ?? []
        )
        object["port"] = connection.server.port
        object["fingerprint"] = connection.server.certFingerprint
        object["token"] = connection.token
        object["updatedAt"] = clock
        object["deleted"] = nil
        object["deletedAt"] = nil
        if let route = SyncedBackendPayload.tunnelAddress(connection.server.tcAddress) {
            object["tcAddress"] = route
        } else if object["tcAddress"] == nil {
            object["tcAddress"] = NSNull()
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func itemQuery(account: String, accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SyncedBackendRegistry.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true
        ]
    }

    // nil is an unknown registry; an empty array is a successful empty read.
    private func readRows() -> [[String: Any]]? { // swiftlint:disable:this discouraged_optional_collection
        guard let accessGroup else { return nil }
        switch keychain.list(matching: SyncedBackendRegistry.listQuery(accessGroup: accessGroup)) {
        case .notFound: return []
        case .rows(let rows): return rows
        case .failure: return nil
        }
    }

    private static func sameRows(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        // Only account and bytes affect our decision. Keychain row ordering
        // and modification-date attributes are not part of the payload.
        func signatures(_ rows: [[String: Any]]) -> [String] {
            rows
                .map { row in
                    let account = row[kSecAttrAccount as String] as? String ?? ""
                    let data = row[kSecValueData as String] as? Data ?? Data()
                    return "\(account)\u{1F}\(data.base64EncodedString())"
                }
                .sorted()
        }
        return signatures(lhs) == signatures(rhs)
    }
}
