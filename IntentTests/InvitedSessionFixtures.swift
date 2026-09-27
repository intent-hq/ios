import Foundation
@testable import Intent
import Testing

enum InvitedSessionFixtures {
    nonisolated private static let pinByteCount = 32
    private static let port = 443
    nonisolated static let pin = String(repeating: "ab", count: pinByteCount)

    static func principal(_ id: String = "B", role: ConnectionPrincipal.HostRole = .member) -> ConnectionPrincipal {
        ConnectionPrincipal(id: id, hostRole: role, revision: 1, login: nil, displayName: nil)
    }

    /// Exact base object from FE25bf invited-session-sync.test.ts. All bearers
    /// are test strings; the controlled authenticator accepts forgotten B too.
    static func session(_ person: String = "B", changes: [String: Any] = [:]) throws -> InvitedSyncRecord {
        var object: [String: Any] = [
            "v": 2, "kind": "session", "fingerprint": pin, "principalId": person,
            "login": NSNull(), "label": "Studio", "host": "old.example", "hosts": ["old.example"], "port": port,
            "hostname": NSNull(), "detectHosts": true, "tcAddress": NSNull(), "tcUpdatedAt": NSNull(),
            "token": "\(person)-still-valid", "updatedAt": 100, "pairedAt": 100,
            "removedThrough": 0, "deleted": false, "deletedAt": NSNull(), "legacyAccounts": ["old.example:443"]
        ]
        object.merge(changes) { _, new in new }
        let account = try InvitedSyncKey.session(fingerprint: pin, principalId: person)
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(InvitedSyncRecord.parse(account: account, data: data))
    }

    static func removal(floor: Double = 200) throws -> InvitedSyncRecord {
        let id = "00000000-0000-4000-8000-000000000001"
        let aliases = ["old.example:443"]
        let key = try InvitedSyncKey.removal(fingerprint: pin, principalId: "B", removalId: id, removedThrough: floor, legacyAccounts: aliases)
        return InvitedSyncRecord(object: [
            "v": 2, "kind": "removal", "fingerprint": pin, "principalId": "B", "removalId": id,
            "removedThrough": floor, "legacyAccounts": aliases
        ], account: key)
    }

    struct Store {
        let persistence: PersistenceManager
        let storage: InMemoryKeychainStorage
        let defaults: UserDefaults
        let suite: String
        let registry: InvitedSessionRegistry

        init(_ cloud: MemorySyncedKeychain) throws {
            suite = "InvitedSessionTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            storage = InMemoryKeychainStorage()
            registry = InvitedSessionRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
            persistence = PersistenceManager(defaults: defaults, keychainStorage: storage, invitedRegistry: registry)
        }

        func close() { defaults.removePersistentDomain(forName: suite) }
        func relaunch() -> PersistenceManager {
            PersistenceManager(defaults: defaults, keychainStorage: storage, invitedRegistry: registry)
        }
    }
}
