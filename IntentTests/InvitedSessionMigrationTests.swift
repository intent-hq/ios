import Foundation
@testable import Intent
import Testing

@MainActor struct InvitedSessionMigrationTests {
    private func legacy(_ person: String?, clock: Double = 100, deleted: Bool = false) -> [String: Any] {
        var object = BackendSyncFixtures.remote(clock: clock, deleted: deleted)
        object["fingerprint"] = InvitedSessionFixtures.pin
        object["principalId"] = person
        object["detectedDeviceKind"] = "laptop"
        object["token"] = deleted ? "" : "\(person ?? "unknown")-still-valid"
        return object
    }

    @Test func legacyLiveNeedsPinnedAuthoritativeIdentityAndRetiresAlias() async throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(legacy(nil))
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        var calls = 0
        _ = await store.persistence.refreshInvitedSessions { candidate in
            calls += 1
            #expect(candidate.server.certFingerprint == InvitedSessionFixtures.pin)
            #expect(candidate.token == "unknown-still-valid")
            return InvitedSessionFixtures.principal()
        }
        #expect(calls > 0)
        let saved = try #require(store.persistence.loadConnections().first)
        let record = try #require(PersistenceManager.invitedRecord(saved))
        #expect(record.pairedAt == 100)
        #expect(record.principalId == "B")
        #expect(record.object["futureMetadata"] is [String: Any])
        #expect(try cloud.object()["kind"] as? String == "legacy-alias")
        // Simulate the documented frozen v1 writer replacing that alias.
        // The separate exported-source proof exercises the actual old reader.
        try cloud.put(legacy("C", clock: 900))
        _ = await store.relaunch().refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        #expect(store.persistence.loadConnections().count == 1)
        #expect(try cloud.object()["kind"] as? String == "legacy-alias")
        #expect(store.persistence.loadConnections().first?.principal?.id == "B")
    }

    @Test func offlineAndMismatchedLegacyCredentialsRemainEncryptedAndUnchanged() async throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(legacy("B"))
        let original = cloud.items
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in throw URLError(.notConnectedToInternet) }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal("C") }
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(cloud.items == original)
        #expect(cloud.writeCount == 0)
    }

    @Test func missingPersonDeletionNeverInfersTheOnlyPersonOnTheHost() async throws {
        let cloud = MemorySyncedKeychain()
        let now = floor(Date().timeIntervalSince1970 * 1000)
        try cloud.put(legacy(nil, clock: now, deleted: true))
        let other = try InvitedSessionFixtures.session("C", changes: ["legacyAccounts": []])
        cloud.items[other.account] = other.data
        let original = cloud.items["mac.local:8843"]
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal("C") }
        #expect(store.persistence.loadConnections().first?.principal?.id == "C")
        #expect(store.persistence.invitedJournal.removals.isEmpty)
        #expect(cloud.items["mac.local:8843"] == original)
    }
}
