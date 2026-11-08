import Foundation
@testable import Intent
import Security
import Testing

@MainActor struct InvitedSessionSyncTests {
    @Test(arguments: [
        (" Mac Studio \n", "tcRoute", "Mac Studio"),
        ("", "Studio", "Studio"),
        (" \n", " Studio ", "Studio"),
        ("", " \n", "old.example:443")
    ])
    func importedNameUsesHostnameBeforeAddressLabel(hostname: String, label: String, expected: String) throws {
        let record = try InvitedSessionFixtures.session(changes: ["hostname": hostname, "label": label])
        let imported = try #require(PersistenceManager.connection(fromInvited: record))
        #expect(imported.displayName == expected)
        #expect(imported.server.name == expected)
    }

    @Test(arguments: [false, true])
    func learnedNameSurvivesCloudFailureReimportAndRelaunch(alreadyNamed: Bool) async throws {
        let cloud = MemorySyncedKeychain()
        let initial = try InvitedSessionFixtures.session(changes: ["label": "tcRoute", "hosts": [], "tcAddress": "tcRoute", "tcUpdatedAt": 100])
        cloud.items[initial.account] = initial.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        var saved = try #require(store.persistence.loadConnections().first)
        if alreadyNamed {
            saved.displayName = "Mac Studio"
            #expect(store.persistence.saveConnectionsLocked([saved]))
        }
        cloud.writeFailure = errSecInteractionNotAllowed
        #expect(store.persistence.updateConnectionDisplayName(id: saved.id, displayName: "Mac Studio"))
        let named = try #require(store.persistence.loadConnections().first)
        let payload = try #require(PersistenceManager.invitedRecord(named))
        #expect(payload.object["hostname"] as? String == "Mac Studio")
        #expect(payload.pairedAt == initial.pairedAt)
        #expect(payload.token == initial.token)
        #expect(payload.routeClock == initial.routeClock)
        #expect(named.pendingSyncUpdatedAt == payload.updatedAt)
        #expect(store.persistence.updateConnectionDisplayName(id: named.id, displayName: "Mac Studio"))
        #expect(store.persistence.loadConnections().first?.pendingSyncUpdatedAt == named.pendingSyncUpdatedAt)
        let relaunched = store.relaunch()
        _ = await relaunched.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        #expect(relaunched.loadConnections().first?.id == saved.id)
        #expect(relaunched.loadConnections().first?.displayName == "Mac Studio")
        cloud.writeFailure = nil
        relaunched.publishPendingInvitedSessions()
        let published = try #require(cloud.items[initial.account].flatMap { InvitedSyncRecord.parse(account: initial.account, data: $0) })
        #expect(published.object["hostname"] as? String == "Mac Studio")
        #expect(published.pairedAt == initial.pairedAt)
        #expect(published.token == initial.token)
        let fresh = try InvitedSessionFixtures.Store(cloud)
        defer { fresh.close() }
        _ = await fresh.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        #expect(fresh.persistence.loadConnections().first?.displayName == "Mac Studio")
        #expect(fresh.persistence.activeConnection() == nil)
    }

    @Test func failedNameSaveKeepsLocalAndCloudRecords() async throws {
        let cloud = MemorySyncedKeychain()
        let initial = try InvitedSessionFixtures.session()
        cloud.items[initial.account] = initial.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let saved = try #require(store.persistence.loadConnections().first)
        let writes = cloud.writeCount
        store.storage.setSaveFailure(true)
        #expect(!store.persistence.updateConnectionDisplayName(id: saved.id, displayName: "Updated Studio"))
        #expect(store.persistence.loadConnections() == [saved])
        #expect(cloud.items[initial.account] == initial.data)
        #expect(cloud.writeCount == writes)
    }

    @Test func importingAnExplicitRouteClearRemovesTheSavedTunnel() async throws {
        let cloud = MemorySyncedKeychain()
        let initial = try InvitedSessionFixtures.session(changes: ["tcAddress": "tcOld", "tcUpdatedAt": 100])
        cloud.items[initial.account] = initial.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        #expect(store.persistence.loadConnections().first?.server.tcAddress == "tcOld")
        let cleared = try InvitedSessionFixtures.session(changes: ["tcAddress": NSNull(), "tcUpdatedAt": 300, "updatedAt": 300])
        cloud.items[cleared.account] = cleared.data
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        #expect(store.persistence.loadConnections().first?.server.tcAddress == nil)
        #expect(store.persistence.loadConnections().first?.token == "B-still-valid")
    }

    @Test func freshClientHonorsIndependentRemovalAfterAStaleWriterWins() async throws {
        let cloud = MemorySyncedKeychain()
        let stale = try InvitedSessionFixtures.session(changes: ["updatedAt": 900, "tcAddress": "tcStale", "tcUpdatedAt": 900])
        let other = try InvitedSessionFixtures.session("C")
        let removal = try InvitedSessionFixtures.removal()
        cloud.items = try [stale.account: #require(stale.data), other.account: #require(other.data), removal.account: #require(removal.data)]
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        var authenticated: [String] = []
        _ = await store.persistence.refreshInvitedSessions { connection in
            authenticated.append(connection.token)
            // The forgotten bearer remains valid on the controlled host.
            return InvitedSessionFixtures.principal(connection.token.hasPrefix("C") ? "C" : "B")
        }
        #expect(authenticated == ["C-still-valid"])
        #expect(store.persistence.loadConnections().map(\.token) == ["C-still-valid"])
        #expect(store.relaunch().invitedJournal.floors[stale.account] == 200)
        #expect(cloud.items[removal.account] == removal.data)
    }

    @Test func forgetSavesFloorBeforeFailedCredentialDeleteAndRetriesSameRemoval() async throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session(changes: ["pairedAt": 8_000_000_000_000_000, "tcUpdatedAt": 8_000_000_000_000_050])
        cloud.items[record.account] = record.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let saved = try #require(store.persistence.loadConnections().first)
        store.storage.setSaveFailure(true)
        #expect(!store.persistence.deleteConnection(id: saved.id))
        let first = store.persistence.invitedJournal
        #expect(try #require(first.floors[record.account]) > 8_000_000_000_000_050)
        #expect(first.removals.count == 1)
        let journalBytes = try JSONEncoder().encode(first)
        #expect(String(data: journalBytes, encoding: .utf8)?.contains("still-valid") == false)
        let relaunched = store.relaunch()
        #expect(!relaunched.deleteConnection(id: saved.id))
        #expect(relaunched.invitedJournal.removals == first.removals)
        store.storage.setSaveFailure(false)
        cloud.writeFailure = errSecInteractionNotAllowed
        #expect(relaunched.deleteConnection(id: saved.id))
        #expect(relaunched.loadConnections().isEmpty)
        cloud.writeFailure = nil
        store.relaunch().publishPendingBackends()
        for (key, data) in first.removals { #expect(cloud.items[key] == data) }
        #expect(cloud.updates.allSatisfy { !($0.query[kSecAttrAccount as String] as? String ?? "").hasPrefix("invited-v2-r:") })
    }

    @Test func repairNeedsCompleteReadAndIsTheOnlyOperationAdvancingPairingClock() throws {
        let cloud = MemorySyncedKeychain()
        let removal = try InvitedSessionFixtures.removal()
        cloud.items[removal.account] = removal.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        var candidate = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session()))
        candidate.principal = InvitedSessionFixtures.principal()
        cloud.readFailure = errSecInteractionNotAllowed
        #expect(throws: PersistenceManager.InvitedPersistenceError.self) { try store.persistence.prepareInvitedPairing(&candidate) }
        cloud.readFailure = nil
        try store.persistence.prepareInvitedPairing(&candidate)
        let repaired = try #require(PersistenceManager.invitedRecord(candidate))
        #expect(repaired.pairedAt > 200)
        #expect(repaired.floor == 200)
        #expect(store.persistence.upsertConnectionWithOutcome(candidate).persisted)
        #expect(store.persistence.updateConnectionTcAddress(id: candidate.id, tcAddress: "tcNew"))
        let patched = try #require(store.persistence.loadConnections().first.flatMap(PersistenceManager.invitedRecord))
        #expect(patched.pairedAt == repaired.pairedAt)
        #expect(cloud.items[removal.account] == removal.data)
        #expect(store.persistence.clearInvitedTunnelRoute(id: candidate.id))
        let cleared = try #require(store.persistence.loadConnections().first.flatMap(PersistenceManager.invitedRecord))
        #expect(cleared.pairedAt == repaired.pairedAt)
        #expect(cleared.object["tcAddress"] is NSNull)
        #expect(cleared.routeClock > patched.routeClock)
    }

    @Test func unknownRemovalDefersAllImportsAndWrites() async throws {
        let cloud = MemorySyncedKeychain()
        let live = try InvitedSessionFixtures.session()
        cloud.items[live.account] = live.data
        cloud.items["invited-v2-r:future"] = Data(#"{"v":3}"#.utf8)
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        var called = false
        _ = await store.persistence.refreshInvitedSessions { _ in called = true; return InvitedSessionFixtures.principal() }
        store.persistence.publishPendingBackends()
        #expect(!called)
        #expect(cloud.writeCount == 0)
        #expect(store.persistence.loadConnections().isEmpty)
    }

    @Test func malformedJournalNeverBecomesAnEmptyRemovalHistory() throws {
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        defer { store.close() }
        store.defaults.set(Data("damaged".utf8), forKey: "invitedSessionSyncJournal")
        var candidate = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session()))
        candidate.principal = InvitedSessionFixtures.principal()
        #expect(throws: PersistenceManager.InvitedPersistenceError.self) { try store.persistence.prepareInvitedPairing(&candidate) }
        #expect(store.defaults.data(forKey: "invitedSessionSyncJournal") == Data("damaged".utf8))
    }

    @Test func revokedOldCredentialCannotForgetNewlyRepairedPerson() async throws {
        let cloud = MemorySyncedKeychain()
        let live = try InvitedSessionFixtures.session()
        cloud.items[live.account] = live.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let before = store.persistence.loadConnections()
        var newPairing = try #require(before.first)
        newPairing.token = "new-valid-bearer"
        try store.persistence.prepareInvitedPairing(&newPairing)
        #expect(store.persistence.upsertConnectionWithOutcome(newPairing).persisted)
        let revoked = NSError(domain: "WebSocket", code: -32_003, userInfo: [NSError.intentErrorDataCodeKey: "access-revoked"])
        store.persistence.recordAuthoritativeRevocation(revoked, observed: before)
        #expect(store.persistence.invitedJournal.removals.isEmpty)
        store.persistence.recordAuthoritativeRevocation(NSError(domain: NSURLErrorDomain, code: -1009), observed: store.persistence.loadConnections())
        #expect(store.persistence.invitedJournal.removals.isEmpty)
        store.persistence.recordAuthoritativeRevocation(revoked, observed: store.persistence.loadConnections())
        #expect(store.persistence.invitedJournal.removals.count == 1)
    }

    @Test(arguments: ["read", "unknown-removal", "frozen-session", "write"])
    func removalPublicationRetriesAfterPostInsertFailure(failure: String) throws {
        let cloud = MemorySyncedKeychain()
        let stale = try InvitedSessionFixtures.session()
        let other = try InvitedSessionFixtures.session("C")
        let removal = try InvitedSessionFixtures.removal()
        let staleData = try #require(stale.data)
        cloud.items = [stale.account: staleData, other.account: try #require(other.data)]
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { cloud.beforeList = nil; store.close() }
        var journal = store.persistence.invitedJournal
        journal.observe([removal])
        store.persistence.invitedJournal = journal
        var injected = false
        let frozen = Data(#"{"v":99}"#.utf8)
        cloud.beforeList = { _ in
            guard !injected, cloud.items[removal.account] != nil else { return }
            injected = true
            switch failure {
            case "read": cloud.readFailure = errSecInteractionNotAllowed
            case "unknown-removal": cloud.items["invited-v2-r:unknown"] = frozen
            case "frozen-session": cloud.items[stale.account] = frozen
            default: cloud.writeFailure = errSecInteractionNotAllowed
            }
        }
        store.persistence.publishPendingInvitedSessions()
        #expect(injected)
        #expect(cloud.items[removal.account] == removal.data)
        #expect(cloud.items[stale.account] == (failure == "frozen-session" ? frozen : staleData))
        #expect(cloud.items[other.account] == other.data)
        #expect(store.persistence.invitedJournal.floors[stale.account] == removal.floor)
        #expect(store.persistence.loadConnections().isEmpty)

        cloud.beforeList = nil
        cloud.readFailure = nil
        cloud.writeFailure = nil
        cloud.items["invited-v2-r:unknown"] = nil
        cloud.items[stale.account] = staleData
        let recovered = store.relaunch()
        recovered.publishPendingInvitedSessions()
        let repairedData = try #require(cloud.items[stale.account])
        let repaired = try #require(InvitedSyncRecord.parse(account: stale.account, data: repairedData))
        #expect(!repaired.live)
        #expect(repaired.floor == removal.floor)
        #expect(cloud.items[removal.account] == removal.data)
        #expect(cloud.items[other.account] == other.data)
        #expect(recovered.loadConnections().isEmpty)
    }

    @Test(arguments: [200.0, 400.0])
    func removalPublicationRefoldsNewerPairingAndConcurrentRemoval(floor: Double) throws {
        let cloud = MemorySyncedKeychain()
        let stale = try InvitedSessionFixtures.session()
        let newer = try InvitedSessionFixtures.session(changes: ["pairedAt": 300, "updatedAt": 300, "token": "B-new"])
        let other = try InvitedSessionFixtures.session("C")
        let removal = try InvitedSessionFixtures.removal()
        let concurrent = try InvitedSessionFixtures.removal(floor: floor)
        cloud.items = [stale.account: try #require(stale.data), other.account: try #require(other.data)]
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { cloud.beforeList = nil; store.close() }
        var journal = store.persistence.invitedJournal
        journal.observe([removal])
        store.persistence.invitedJournal = journal
        var injected = false
        cloud.beforeList = { _ in
            guard !injected, cloud.items[removal.account] != nil else { return }
            injected = true
            cloud.items[newer.account] = newer.data
            cloud.items[concurrent.account] = concurrent.data
        }
        store.persistence.publishPendingInvitedSessions()
        #expect(injected)
        let publishedData = try #require(cloud.items[stale.account])
        let published = try #require(InvitedSyncRecord.parse(account: stale.account, data: publishedData))
        #expect(published.live == (floor < newer.pairedAt))
        if published.live {
            #expect(cloud.items[newer.account] == newer.data)
        } else {
            #expect(published.floor == floor)
            #expect(published.token.isEmpty)
        }
        #expect(store.relaunch().invitedJournal.floors[stale.account] == floor)
        #expect(cloud.items[removal.account] == removal.data)
        #expect(cloud.items[concurrent.account] == concurrent.data)
        #expect(cloud.items[other.account] == other.data)
    }
}
