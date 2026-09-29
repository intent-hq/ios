import Foundation

/// Raw fields survive rewrites; a parser rejection freezes the original bytes.
struct InvitedSyncRecord {
    var object: [String: Any]
    let account: String
    var kind: String { object["kind"] as? String ?? "" }
    var fingerprint: String { object["fingerprint"] as? String ?? "" }
    var principalId: String { object["principalId"] as? String ?? "" }
    var personKey: String? { try? InvitedSyncKey.session(fingerprint: fingerprint, principalId: principalId) }
    var floor: Double { ConnectionPrincipal.number(object["removedThrough"]) ?? 0 }
    var updatedAt: Double { ConnectionPrincipal.number(object["updatedAt"]) ?? 0 }
    var pairedAt: Double { ConnectionPrincipal.number(object["pairedAt"]) ?? 0 }
    var legacyAccounts: [String] { object["legacyAccounts"] as? [String] ?? [] }
    var token: String { object["token"] as? String ?? "" }
    var live: Bool { kind == "session" && object["deleted"] as? Bool == false && pairedAt > floor }
    var data: Data? { try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    var routeAccount: String { Self.legacyAccount(host: object["host"] as? String ?? "", port: object["port"] as? Int ?? 0) }
    var routeClock: Double { ConnectionPrincipal.number(object["tcUpdatedAt"]) ?? -1 }

    static func parse(account: String, data: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ConnectionPrincipal.number(object["v"]) == 2 else { return nil }
        let record = Self(object: object, account: account)
        if record.kind == "legacy-alias" {
            guard validLegacyAccount(account), let keys = stringSet(object["personKeys"]),
                  keys.allSatisfy(isPersonKey) else { return nil }
            return record
        }
        guard !record.principalId.isEmpty, (try? InvitedSyncKey.fingerprint(record.fingerprint)) == record.fingerprint,
              let aliases = stringSet(object["legacyAccounts"]), aliases.allSatisfy(validLegacyAccount),
              ConnectionPrincipal.validClock(ConnectionPrincipal.number(object["removedThrough"])) else { return nil }
        if record.kind == "removal" { return validRemoval(record) ? record : nil }
        guard record.personKey == account, ConnectionPrincipal.validClock(ConnectionPrincipal.number(object["updatedAt"])) else { return nil }
        if record.kind == "removed" { return (object["token"] as? String)?.isEmpty == true ? record : nil }
        return validSession(record) ? record : nil
    }

    private static func validRemoval(_ record: Self) -> Bool {
        let forbidden = [
            "token", "login", "label", "host", "hosts", "port", "hostname", "tcAddress", "tcUpdatedAt", "detectHosts",
            "accent", "detectedDeviceKind", "deviceIcon", "identity", "hostRole", "avatarUrl", "displayName"
        ]
        guard !forbidden.contains(where: { record.object[$0] != nil }), let removalId = record.object["removalId"] as? String else { return false }
        return (try? InvitedSyncKey.removal(
            fingerprint: record.fingerprint,
            principalId: record.principalId,
            removalId: removalId,
            removedThrough: record.floor,
            legacyAccounts: record.legacyAccounts
        )) == record.account
    }

    private static func validSession(_ record: Self) -> Bool {
        let row = record.object
        guard record.kind == "session", row["label"] is String,
              nullableString(row["login"]), let host = row["host"] as? String, !host.isEmpty,
              let hosts = row["hosts"] as? [String], hosts.allSatisfy({ !$0.isEmpty }),
              let port = ConnectionPrincipal.number(row["port"]), validPort(port),
              nullableString(row["hostname"]), ConnectionPrincipal.boolean(row["detectHosts"]) != nil,
              nullableString(row["tcAddress"]), row["tcUpdatedAt"] is NSNull || ConnectionPrincipal.validClock(ConnectionPrincipal.number(row["tcUpdatedAt"])),
              ConnectionPrincipal.validClock(ConnectionPrincipal.number(row["pairedAt"])),
              let deleted = ConnectionPrincipal.boolean(row["deleted"]), validPreferences(row) else { return false }
        return deleted
            ? (row["token"] as? String)?.isEmpty == true && ConnectionPrincipal.validClock(ConnectionPrincipal.number(row["deletedAt"]))
            : !record.token.isEmpty && row["deletedAt"] is NSNull
    }

    static func validPort(_ port: Double) -> Bool { port >= 1 && port <= Double(UInt16.max) && port.rounded(.down) == port }
    static func nullableString(_ value: Any?) -> Bool { value is NSNull || value is String }

    // nil distinguishes an invalid field from a valid empty alias set.
    static func stringSet(_ value: Any?) -> [String]? { // swiftlint:disable:this discouraged_optional_collection
        guard let values = value as? [String], values.allSatisfy({ !$0.isEmpty }),
              values.map({ Data($0.utf8) }) == InvitedSyncKey.sorted(values).map({ Data($0.utf8) }) else { return nil }
        return values
    }

    private static func validPreferences(_ row: [String: Any]) -> Bool {
        let accents = ["blue", "indigo", "violet", "rose", "orange", "emerald", "teal"]
        let detected = ["macMini", "macStudio", "laptop", "desktop", "server", "cloudVm"]
        let icons = detected + ["auto", "robot", "rocket", "flyingSaucer", "ghost", "cat", "dog", "gameController", "coffee", "planet", "pottedPlant"]
        func valid(_ key: String, choices: [String], nullable: Bool) -> Bool {
            guard let value = row[key] else { return true }
            return nullable && value is NSNull || (value as? String).map(choices.contains) == true
        }
        return valid("accent", choices: accents, nullable: true)
            && valid("detectedDeviceKind", choices: detected, nullable: true)
            && valid("deviceIcon", choices: icons, nullable: false)
    }

    static func isPersonKey(_ value: String) -> Bool {
        value.range(of: "^invited-v2-s:[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    static func legacyAccount(host: String, port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
    }

    static func validLegacyAccount(_ value: String) -> Bool {
        guard let split = value.lastIndex(of: ":"), let port = Int(value[value.index(after: split)...]) else { return false }
        let host = String(value[..<split])
        return !host.isEmpty && validPort(Double(port)) && legacyAccount(host: host, port: port) == value
    }
}
