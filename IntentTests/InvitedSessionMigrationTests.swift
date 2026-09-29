import Foundation
@testable import Intent
import Security
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
        defer { cloud.beforeWrite = nil; store.close() }
        cloud.beforeWrite = {
            let saved = store.persistence.loadConnections()
            #expect(saved.count == 1)
            #expect(saved.first?.principal?.id == "B")
            #expect(saved.first?.invitedSyncPayload != nil)
        }
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

    @Test(arguments: [false, true])
    func failedLegacySaveRetriesWithoutRetiringAlias(relaunch: Bool) async throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(legacy("B"))
        let original = cloud.items
        let key = try InvitedSyncKey.session(fingerprint: InvitedSessionFixtures.pin, principalId: "B")
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        store.storage.setSaveFailure(true)
        var attemptedImport = false
        _ = await store.persistence.refreshInvitedSessions { candidate in
            if candidate.invitedSyncPayload != nil { attemptedImport = true }
            return InvitedSessionFixtures.principal()
        }
        #expect(attemptedImport)
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(cloud.items == original)
        #expect(cloud.writeCount == 0)
        #expect(store.persistence.invitedJournal.retired["mac.local:8843"] == nil)
        #expect(store.persistence.invitedJournal.floors[key] == nil)

        store.storage.setSaveFailure(false)
        let recovered = relaunch ? store.relaunch() : store.persistence
        var retriedImport = false
        _ = await recovered.refreshInvitedSessions { candidate in
            if candidate.invitedSyncPayload != nil { retriedImport = true }
            return InvitedSessionFixtures.principal()
        }
        #expect(retriedImport)
        let saved = try #require(recovered.loadConnections().first)
        #expect(saved.principal?.id == "B")
        #expect(saved.token == "B-still-valid")
        #expect(PersistenceManager.invitedRecord(saved)?.pairedAt == 100)
        #expect(recovered.invitedJournal.retired["mac.local:8843"] == [key])
        #expect(try cloud.object()["kind"] as? String == "legacy-alias")
        #expect(store.relaunch().loadConnections().map(\.id) == [saved.id])
    }

    @Test func savingOneMigratedPersonDoesNotRetireAnotherFailedCandidate() async throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(legacy("B"))
        let original = cloud.items["mac.local:8843"]
        var other = legacy("C")
        other["host"] = "other.local"
        other["hosts"] = ["other.local"]
        try cloud.put(other, account: "other.local:8843")
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { candidate in
            let isOther = candidate.token == "C-still-valid"
            store.storage.setSaveFailure(!isOther)
            return InvitedSessionFixtures.principal(isOther ? "C" : "B")
        }
        #expect(store.persistence.loadConnections().map { $0.principal?.id } == ["C"])
        #expect(store.persistence.invitedJournal.retired["mac.local:8843"] == nil)
        #expect(cloud.items["mac.local:8843"] == original)
        #expect(try cloud.object(account: "other.local:8843")["kind"] as? String == "legacy-alias")
        store.storage.setSaveFailure(false)
        let recovered = store.relaunch()
        _ = await recovered.refreshInvitedSessions { candidate in
            InvitedSessionFixtures.principal(candidate.token == "C-still-valid" ? "C" : "B")
        }
        #expect(recovered.loadConnections().compactMap { $0.principal?.id }.sorted() == ["B", "C"])
        #expect(try cloud.object()["kind"] as? String == "legacy-alias")
    }

    @Test func removalObservedDuringMigrationSurvivesFailedStorageAndStaleRelaunch() async throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(legacy("B"))
        let removal = try InvitedSessionFixtures.removal()
        let stale = try InvitedSessionFixtures.session()
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        store.storage.setSaveFailure(true)
        cloud.writeFailure = errSecInteractionNotAllowed
        var observedRemoval = false
        _ = await store.persistence.refreshInvitedSessions { candidate in
            if candidate.invitedSyncPayload != nil {
                observedRemoval = true
                cloud.items[removal.account] = removal.data
            }
            return InvitedSessionFixtures.principal()
        }
        #expect(observedRemoval)
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(store.persistence.invitedJournal.floors[stale.account] == removal.floor)
        let remembered = try #require(store.persistence.invitedJournal.removals[removal.account])

        // A later cloud snapshot loses the removal and reintroduces the still-valid
        // old credential. Durable local removal evidence must beat both v1 and v2.
        cloud.items[removal.account] = nil
        cloud.items[stale.account] = stale.data
        cloud.writeFailure = nil
        store.storage.setSaveFailure(false)
        let recovered = store.relaunch()
        _ = await recovered.refreshInvitedSessions { _ in
            Issue.record("A stale credential covered by a durable removal was authenticated")
            return InvitedSessionFixtures.principal()
        }
        #expect(recovered.loadConnections().isEmpty)
        #expect(recovered.invitedJournal.floors[stale.account] == removal.floor)
        #expect(recovered.invitedJournal.removals[removal.account] == remembered)
        #expect(cloud.items[removal.account] == remembered)
        let tombstoneData = try #require(cloud.items[stale.account])
        let tombstone = try #require(InvitedSyncRecord.parse(account: stale.account, data: tombstoneData))
        #expect(!tombstone.live)
        #expect(tombstone.floor == removal.floor)
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
