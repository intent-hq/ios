import Foundation

enum InvitedLegacyMigration {
    struct Candidate {
        let account: String
        let object: [String: Any]
        let legacy: SyncedBackendRecord
        let principalId: String?
        let fingerprint: String

        var personKey: String? { principalId.flatMap { try? InvitedSyncKey.session(fingerprint: fingerprint, principalId: $0) } }
    }

    static func candidates(_ snapshot: InvitedSessionRegistry.Snapshot, journal: InvitedSyncJournal) -> [Candidate] {
        snapshot.entries.compactMap { entry in
            guard journal.retired[entry.account] == nil,
                  InvitedSessionRegistry.knownLegacy(entry.data),
                  let object = try? JSONSerialization.jsonObject(with: entry.data) as? [String: Any],
                  let text = String(data: entry.data, encoding: .utf8),
                  case .record(let record) = SyncedBackendPayload.parse(text),
                  record.accountKey == entry.account,
                  object["pairedAt"] == nil || ConnectionPrincipal.validClock(ConnectionPrincipal.number(object["pairedAt"])),
                  ConnectionPrincipal.validClock(record.updatedAt),
                  let pin = try? InvitedSyncKey.fingerprint(record.fingerprint),
                  !record.isExpiredTombstone(now: Date()) else { return nil }
            let principal = (object["principalId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let candidate = Candidate(account: entry.account, object: object, legacy: record, principalId: principal, fingerprint: pin)
            if let key = candidate.personKey,
               snapshot.records.contains(where: { $0.personKey == key }) || snapshot.frozen(key) { return nil }
            return candidate
        }
    }

    static func session(_ candidate: Candidate, principal: ConnectionPrincipal) -> InvitedSyncRecord? {
        guard !principal.isOwner,
              candidate.principalId.map({ ConnectionPrincipal.samePerson($0, principal.id) }) ?? true,
              let key = try? InvitedSyncKey.session(fingerprint: candidate.fingerprint, principalId: principal.id) else { return nil }
        let legacy = candidate.legacy
        var object = candidate.object
        object.merge([
            "v": 2, "kind": "session", "fingerprint": candidate.fingerprint, "principalId": principal.id,
            "login": principal.login as Any? ?? NSNull(), "hostname": legacy.hostname as Any? ?? NSNull(),
            "host": legacy.host, "hosts": legacy.hosts, "port": legacy.port, "detectHosts": legacy.detectHosts,
            "label": legacy.label, "token": legacy.token, "updatedAt": legacy.updatedAt,
            "pairedAt": ConnectionPrincipal.number(candidate.object["pairedAt"]) ?? legacy.updatedAt,
            "removedThrough": 0, "deleted": false, "deletedAt": NSNull(),
            "legacyAccounts": [candidate.account], "tcAddress": legacy.tcAddress as Any? ?? NSNull(),
            "tcUpdatedAt": legacy.tcAddress == nil ? NSNull() : legacy.updatedAt
        ]) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return InvitedSyncRecord.parse(account: key, data: data)
    }
}
