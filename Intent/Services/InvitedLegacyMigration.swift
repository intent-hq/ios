import CryptoKit
import Foundation

/// Local, token-free provenance for a row seen before its alias retired.
/// The digest permits only these exact bytes in this exact access group;
/// a bound person must still be authenticated on every retry.
struct InvitedLegacyMigrationReceipt: Codable, Equatable {
    private static let formatVersion = 1
    private static let digestBytes = 32
    let version: Int
    let account: String
    let group: String?
    let rowDigest: Data
    let pairedAt: Double
    var personKey: String?
    var invalidated = false

    private enum CodingKeys: String, CodingKey { case version, account, group, rowDigest, pairedAt, personKey, invalidated }

    init(_ candidate: InvitedLegacyMigration.Candidate, source: InvitedSessionRegistry.Entry) {
        version = Self.formatVersion
        account = source.account
        group = source.group
        rowDigest = Data(SHA256.hash(data: source.data))
        pairedAt = ConnectionPrincipal.number(candidate.object["pairedAt"]) ?? candidate.legacy.updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        account = try values.decode(String.self, forKey: .account)
        group = try values.decodeIfPresent(String.self, forKey: .group)
        rowDigest = try values.decode(Data.self, forKey: .rowDigest)
        pairedAt = try values.decode(Double.self, forKey: .pairedAt)
        personKey = try values.decodeIfPresent(String.self, forKey: .personKey)
        invalidated = try values.decode(Bool.self, forKey: .invalidated)
        let validPerson = personKey.map { key in
            let digest = String(key.dropFirst(InvitedSyncKey.sessionPrefix.count))
            return key.hasPrefix(InvitedSyncKey.sessionPrefix) && (try? InvitedSyncKey.fingerprint(digest)) == digest
        } ?? true
        guard version == Self.formatVersion, !account.isEmpty, group?.isEmpty != true,
              rowDigest.count == Self.digestBytes, ConnectionPrincipal.validClock(pairedAt), validPerson else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported or malformed local migration receipt")
        }
    }

    func matches(_ source: InvitedSessionRegistry.Entry) -> Bool {
        account.utf8.elementsEqual(source.account.utf8)
            && group.map { Data($0.utf8) } == source.group.map { Data($0.utf8) }
            && rowDigest == Data(SHA256.hash(data: source.data))
    }

    func covered(by records: [InvitedSyncRecord], floors: [String: Double]) -> Bool {
        guard let personKey else { return false }
        let floor = floors[personKey] ?? 0
        return floor > 0 && floor >= pairedAt
            || records.contains { $0.personKey == personKey && $0.live && $0.pairedAt >= pairedAt }
    }
}

enum InvitedLegacyMigration {
    typealias Receipt = InvitedLegacyMigrationReceipt

    struct Candidate {
        let account: String
        let object: [String: Any]
        let legacy: SyncedBackendRecord
        let principalId: String?
        let fingerprint: String
        var source: InvitedSessionRegistry.Entry?

        var personKey: String? { principalId.flatMap { try? InvitedSyncKey.session(fingerprint: fingerprint, principalId: $0) } }
    }

    static func candidates(_ snapshot: InvitedSessionRegistry.Snapshot, journal: InvitedSyncJournal) -> [Candidate] {
        snapshot.entries.compactMap { entry in
            guard journal.permitsLegacySource(entry),
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
            let candidate = Candidate(account: entry.account, object: object, legacy: record, principalId: principal, fingerprint: pin, source: entry)
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
