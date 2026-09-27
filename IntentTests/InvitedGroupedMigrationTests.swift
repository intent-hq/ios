import Foundation
@testable import Intent
import Security
import Testing

/// Models SecItem's access-group + account identity, including the unscoped
/// query returning both readable groups rather than collapsing their rows.
nonisolated private final class GroupedInvitedKeychain: SyncedKeychainWriting {
    struct ItemKey: Hashable {
        let group: String
        let account: String
    }

    static let privateGroup = "TESTTEAM.dev.intentapp.private"
    static let alias = "mac.local:8843"
    var items: [ItemKey: Data] = [:]

    @MainActor func put(_ person: String, group: String, clock: Double = 100) throws {
        var object = BackendSyncFixtures.remote(clock: clock)
        object["fingerprint"] = InvitedSessionFixtures.pin
        object["principalId"] = person
        object["token"] = "\(person)-still-valid"
        object["detectedDeviceKind"] = "laptop"
        items[ItemKey(group: group, account: Self.alias)] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func list(matching query: [String: Any]) -> SyncedKeychainListOutcome {
        .rows(matching(query).compactMap { key in
            guard let data = items[key] else { return nil }
            return [kSecAttrAccount as String: key.account, kSecAttrAccessGroup as String: key.group, kSecValueData as String: data]
        })
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let group = attributes[kSecAttrAccessGroup as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        let key = ItemKey(group: group, account: account)
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = data
        return errSecSuccess
    }

    func update(matching query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        let keys = matching(query)
        guard !keys.isEmpty else { return errSecItemNotFound }
        for key in keys { items[key] = data }
        return errSecSuccess
    }

    func delete(matching query: [String: Any]) -> OSStatus {
        for key in matching(query) { items[key] = nil }
        return errSecSuccess
    }

    private func matching(_ query: [String: Any]) -> [ItemKey] {
        let group = query[kSecAttrAccessGroup as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        return items.keys.filter { (group == nil || $0.group == group) && (account == nil || $0.account == account) }
    }
}

@MainActor struct InvitedGroupedMigrationTests {
    private func cloud() throws -> GroupedInvitedKeychain {
        let cloud = GroupedInvitedKeychain()
        try cloud.put("B", group: BackendSyncFixtures.accessGroup)
        try cloud.put("C", group: GroupedInvitedKeychain.privateGroup)
        return cloud
    }

    private func principal(_ candidate: StoredConnection) -> ConnectionPrincipal {
        InvitedSessionFixtures.principal(candidate.token == "B-still-valid" ? "B" : "C")
    }

    @Test(arguments: ["B", "C"], [false, true])
    func sharedAliasRetriesOnlyTheFailedPerson(failedPerson: String, relaunch: Bool) async throws {
        let cloud = try cloud()
        let original = cloud.items
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        let snapshot = try #require(store.registry.read())
        #expect(Set(snapshot.entries.compactMap(\.group)) == Set([BackendSyncFixtures.accessGroup, GroupedInvitedKeychain.privateGroup]))
        _ = await store.persistence.refreshInvitedSessions { candidate in
            let principal = principal(candidate)
            store.storage.setSaveFailure(principal.id == failedPerson)
            return principal
        }
        let first = try #require(store.persistence.loadConnections().first)
        #expect(first.principal?.id != failedPerson)
        #expect(store.persistence.loadConnections().count == 1)
        for (key, bytes) in original { #expect(cloud.items[key] == bytes) }

        store.storage.setSaveFailure(false)
        let recovered = relaunch ? store.relaunch() : store.persistence
        _ = await recovered.refreshInvitedSessions { candidate in principal(candidate) }
        let saved = recovered.loadConnections()
        #expect(saved.compactMap { $0.principal?.id }.sorted() == ["B", "C"])
        #expect(Set(saved.map(\.id)).count == 2)
        let restoredFirst = saved.first { $0.principal?.id == first.principal?.id }
        #expect(restoredFirst?.id == first.id)
        #expect(saved.map(\.token).sorted() == ["B-still-valid", "C-still-valid"])
        #expect(Set(store.relaunch().loadConnections().map(\.id)) == Set(saved.map(\.id)))
        let aliasKey = GroupedInvitedKeychain.ItemKey(group: BackendSyncFixtures.accessGroup, account: GroupedInvitedKeychain.alias)
        let marker = try #require(InvitedSyncRecord.parse(account: aliasKey.account, data: try #require(cloud.items[aliasKey])))
        #expect(marker.kind == "legacy-alias")
        #expect((marker.object["personKeys"] as? [String])?.sorted() == saved.compactMap(\.invitedPersonKey).sorted())

        // A frozen v1 writer can overwrite the shared alias after completion;
        // neither its newer clock nor another claimed person reopens migration.
        try cloud.put("D", group: BackendSyncFixtures.accessGroup, clock: 900)
        _ = await store.relaunch().refreshInvitedSessions { candidate in
            #expect(candidate.token != "D-still-valid")
            return principal(candidate)
        }
        #expect(Set(recovered.loadConnections().map(\.id)) == Set(saved.map(\.id)))
        #expect(recovered.loadConnections().map(\.token).sorted() == ["B-still-valid", "C-still-valid"])
    }

    @Test func pendingSourceCannotBeReplacedByAnotherGroupOrStaleWriter() async throws {
        let cloud = try cloud()
        let source = GroupedInvitedKeychain.ItemKey(group: BackendSyncFixtures.accessGroup, account: GroupedInvitedKeychain.alias)
        let original = try #require(cloud.items[source])
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { candidate in
            store.storage.setSaveFailure(candidate.token == "B-still-valid")
            return principal(candidate)
        }
        store.storage.setSaveFailure(false)
        try cloud.put("D", group: source.group, clock: 900)
        let moved = GroupedInvitedKeychain.ItemKey(group: "TESTTEAM.other", account: source.account)
        cloud.items[moved] = original
        let recovered = store.relaunch()
        _ = await recovered.refreshInvitedSessions { candidate in
            #expect(candidate.token == "C-still-valid")
            return principal(candidate)
        }
        #expect(recovered.loadConnections().compactMap { $0.principal?.id } == ["C"])
        cloud.items[moved] = nil
        cloud.items[source] = original
        _ = await recovered.refreshInvitedSessions { candidate in principal(candidate) }
        #expect(recovered.loadConnections().map(\.token).sorted() == ["B-still-valid", "C-still-valid"])
    }

    @Test func offlinePeerKeepsItsOriginalGroupRowUntilAuthenticated() async throws {
        let cloud = try cloud()
        let original = cloud.items
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { candidate in
            if candidate.token == "B-still-valid" { throw URLError(.notConnectedToInternet) }
            return principal(candidate)
        }
        #expect(store.persistence.loadConnections().compactMap { $0.principal?.id } == ["C"])
        for (key, bytes) in original { #expect(cloud.items[key] == bytes) }
        let recovered = store.relaunch()
        _ = await recovered.refreshInvitedSessions { candidate in principal(candidate) }
        #expect(recovered.loadConnections().map(\.token).sorted() == ["B-still-valid", "C-still-valid"])
    }
}
