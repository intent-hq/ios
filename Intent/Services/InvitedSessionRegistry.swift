import Foundation
import Security

/// The existing desktop invited-session service, using the same Security seam
/// and access group as owner sync. Its v2 dispatch never changes owner v1.
struct InvitedSessionRegistry {
    static let service = "com.cloudlands.intent.guest-sessions"
    let keychain: any SyncedKeychainWriting
    let accessGroup: String?
    var enabled = true

    static func production() -> Self? {
        guard let publisher = SyncedBackendPublisher.production() else { return nil }
        return Self(keychain: publisher.keychain, accessGroup: publisher.accessGroup)
    }

    struct Entry {
        let account: String
        let data: Data
        let group: String?
        var record: InvitedSyncRecord? { InvitedSyncRecord.parse(account: account, data: data) }
    }

    struct Snapshot {
        let entries: [Entry]
        var records: [InvitedSyncRecord] { entries.compactMap(\.record) }
        var removalStateUnknown: Bool {
            entries.contains { $0.account.hasPrefix(InvitedSyncKey.removalPrefix) && $0.record?.kind != "removal" }
        }

        func frozen(_ account: String) -> Bool {
            entries.contains { $0.account == account && $0.record == nil }
        }
    }

    /// Both groups must be readable before any migration or live publication.
    func read() -> Snapshot? {
        guard enabled, let accessGroup else { return nil }
        var entries: [Entry] = []
        for group in [accessGroup, nil] {
            var query = itemQuery(account: nil, group: group)
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            switch keychain.list(matching: query) {
            case .failure: return nil
            case .notFound: break
            case .rows(let rows):
                for row in rows {
                    guard let account = row[kSecAttrAccount as String] as? String,
                          let data = row[kSecValueData as String] as? Data else { return nil }
                    entries.append(Entry(account: account, data: data, group: row[kSecAttrAccessGroup as String] as? String ?? group))
                }
            }
        }
        return Snapshot(entries: entries)
    }

    /// Removal insertion is create-only. Even the duplicate path never updates
    /// a row; equal known fields acknowledge it while preserving unknown bytes.
    func insertRemoval(_ record: InvitedSyncRecord) -> Bool {
        guard enabled, let accessGroup, record.kind == "removal", let data = record.data,
              InvitedSyncRecord.parse(account: record.account, data: data) != nil else { return false }
        guard let before = read(), !before.removalStateUnknown else { return false }
        var attributes = itemQuery(account: record.account, group: accessGroup)
        attributes[kSecAttrSynchronizable as String] = true
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = data
        let status = keychain.add(attributes)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem, let snapshot = read(), !snapshot.removalStateUnknown else { return false }
        let copies = snapshot.entries.filter { $0.account == record.account && $0.group == accessGroup }
        return !copies.isEmpty && copies.allSatisfy { entry in
            guard let old = entry.record else { return false }
            // The account hashes every immutable field; re-derivation above
            // establishes equality without rewriting unknown extension fields.
            return old.kind == "removal" && old.account == record.account
        }
    }

    func writeMutable(_ record: InvitedSyncRecord, snapshot: Snapshot) -> Bool {
        guard enabled, let accessGroup, record.kind != "removal", let data = record.data,
              InvitedSyncRecord.parse(account: record.account, data: data) != nil,
              !snapshot.removalStateUnknown else { return false }
        guard let fresh = read(), !fresh.removalStateUnknown,
              signature(fresh) == signature(snapshot) else { return false }
        let copies = snapshot.entries.filter { $0.account == record.account }
        guard copies.allSatisfy({ $0.record != nil || record.kind == "legacy-alias" && Self.knownLegacy($0.data) }) else { return false }
        let query = itemQuery(account: record.account, group: accessGroup)
        let status: OSStatus
        if copies.contains(where: { $0.group == accessGroup }) {
            status = keychain.update(matching: query, attributes: [kSecValueData as String: data])
        } else {
            var attributes = query
            attributes[kSecAttrSynchronizable as String] = true
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecValueData as String] = data
            status = keychain.add(attributes)
        }
        guard status == errSecSuccess else { return false }
        // Only clean up a classified legacy-group copy AFTER destination save.
        for copy in copies where copy.group != accessGroup && copy.record != nil {
            guard let group = copy.group else { continue }
            _ = keychain.delete(matching: itemQuery(account: copy.account, group: group))
        }
        return true
    }

    private func signature(_ snapshot: Snapshot) -> [String] {
        snapshot.entries.map { "\($0.group ?? "")|\($0.account)|\($0.data.base64EncodedString())" }.sorted()
    }

    static func knownLegacy(_ data: Data) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ConnectionPrincipal.number(raw["v"]) == 1,
              let text = String(data: data, encoding: .utf8),
              case .record = SyncedBackendPayload.parse(text) else { return false }
        return true
    }

    func itemQuery(account: String?, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}
