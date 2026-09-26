import Foundation

enum InvitedSyncMerge {
    static func person(_ records: [InvitedSyncRecord], rememberedFloor: Double = 0, now: Date = Date()) -> InvitedSyncRecord? {
        guard let first = records.first, let key = first.personKey,
              records.allSatisfy({ $0.personKey == key }) else { return nil }
        let floor = max(rememberedFloor, records.map(\.floor).max() ?? 0)
        let aliases = InvitedSyncKey.sorted(records.flatMap(\.legacyAccounts))
        let extensions = preservedExtensions(records)
        let live = records.filter { $0.live && $0.pairedAt > floor }
        guard let metadata = live.max(by: metadataOrder), let credential = live.max(by: { $0.pairedAt < $1.pairedAt }) else {
            let millisecondsPerSecond: Double = 1000
            if var details = records.filter({ $0.kind == "session" }).max(by: metadataOrder),
               now.timeIntervalSince1970 * millisecondsPerSecond - floor <= SyncedBackendRecord.tombstoneTTLMs {
                details.object = extensions.merging(details.object) { _, new in new }
                details.object.merge([
                    "token": "", "updatedAt": floor, "removedThrough": floor, "legacyAccounts": aliases, "deleted": true, "deletedAt": floor
                ]) { _, new in new }
                return details
            }
            var object = extensions
            object.merge([
                "v": 2, "kind": "removed", "fingerprint": first.fingerprint, "principalId": first.principalId,
                "token": "", "updatedAt": floor, "removedThrough": floor, "legacyAccounts": aliases
            ]) { _, new in new }
            return InvitedSyncRecord(object: object, account: key)
        }
        let route = live.max { lhs, rhs in
            if lhs.routeClock != rhs.routeClock { return lhs.routeClock < rhs.routeClock }
            if (lhs.object["tcAddress"] is NSNull) != (rhs.object["tcAddress"] is NSNull) { return rhs.object["tcAddress"] is NSNull }
            return lhs.routeAccount.utf8.lexicographicallyPrecedes(rhs.routeAccount.utf8)
        } ?? metadata
        var result = metadata
        result.object = extensions.merging(result.object) { _, new in new }
        result.object["token"] = credential.token
        result.object["pairedAt"] = credential.pairedAt
        result.object["login"] = credential.object["login"]
        result.object["tcAddress"] = route.object["tcAddress"]
        result.object["tcUpdatedAt"] = route.object["tcUpdatedAt"]
        result.object["removedThrough"] = floor
        result.object["legacyAccounts"] = aliases
        return result
    }

    private static func preservedExtensions(_ records: [InvitedSyncRecord]) -> [String: Any] {
        let known = Set([
            "v", "kind", "fingerprint", "principalId", "token", "updatedAt", "removedThrough", "legacyAccounts",
            "label", "login", "host", "hosts", "port", "hostname", "detectHosts", "tcAddress", "tcUpdatedAt",
            "pairedAt", "deleted", "deletedAt", "accent", "detectedDeviceKind", "deviceIcon"
        ])
        var result: [String: Any] = [:]
        for record in records where record.kind != "removal" {
            result.merge(record.object.filter { !known.contains($0.key) }) { _, new in new }
        }
        return result
    }

    private static func metadataOrder(_ lhs: InvitedSyncRecord, _ rhs: InvitedSyncRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.routeAccount.utf8.lexicographicallyPrecedes(rhs.routeAccount.utf8)
    }
}

/// Token-free removal memory/outbox, alongside the existing backend journal.
/// Saved before credential writes so a locked Keychain cannot undo forgetting.
struct InvitedSyncJournal: Codable {
    var floors: [String: Double] = [:]
    var removals: [String: Data] = [:]
    var retired: [String: [String]] = [:]
    var clock: Double = 0

    mutating func observe(_ records: [InvitedSyncRecord]) {
        for record in records {
            if record.kind == "removal", let data = record.data { removals[record.account] = data }
            clock = max(clock, record.updatedAt, record.pairedAt, record.floor, record.routeClock)
            if record.kind == "legacy-alias" {
                retire(record.account, people: record.object["personKeys"] as? [String] ?? [])
            } else if let key = record.personKey {
                floors[key] = max(floors[key] ?? 0, record.floor)
                for alias in record.legacyAccounts { retire(alias, people: [key]) }
            }
        }
    }

    mutating func retire(_ account: String, people: [String]) {
        retired[account] = InvitedSyncKey.sorted((retired[account] ?? []) + people)
    }

    mutating func nextClock(now: Date) throws -> Double {
        let millisecondsPerSecond: Double = 1000
        let next = max(floor(now.timeIntervalSince1970 * millisecondsPerSecond), clock + 1)
        guard ConnectionPrincipal.validClock(next) else { throw InvitedSyncKey.Invalid.input }
        clock = next
        return next
    }
}
