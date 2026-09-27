import Foundation
@testable import Intent
import Security
import Testing

@MainActor struct InvitedSessionRaceTests {
    @Test(arguments: [false, true]) func lateImportPreservesNewerLocalMetadataAndRoute(clear: Bool) async throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session(changes: ["tcAddress": "tcOld", "tcUpdatedAt": 100])
        cloud.items[record.account] = record.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let gate = TestGate()
        defer { gate.open() }
        var waiting = false
        let refresh = Task {
            await store.persistence.refreshInvitedSessions { candidate in
                #expect(candidate.server.tcAddress == "tcOld")
                waiting = true
                await gate.wait()
                return InvitedSessionFixtures.principal()
            }
        }
        try await waitUntil("import authentication suspended") { waiting }
        var local = try #require(store.persistence.loadConnections().first)
        let route: Any = clear ? NSNull() : "tcNew"
        let newer = try InvitedSessionFixtures.session(changes: [
            "tcAddress": route, "tcUpdatedAt": 500, "updatedAt": 500, "label": "Renamed locally"
        ])
        let candidate = try #require(PersistenceManager.connection(fromInvited: newer))
        local.server = candidate.server
        local.displayName = "Renamed locally"
        local.invitedSyncPayload = newer.data
        local.pendingSyncUpdatedAt = 500
        #expect(store.persistence.saveConnectionsLocked([local]))
        cloud.writeFailure = errSecInteractionNotAllowed
        gate.open()
        _ = await refresh.value
        let saved = try #require(store.persistence.loadConnections().first)
        #expect(saved.displayName == "Renamed locally")
        #expect(saved.server.tcAddress == (clear ? nil : "tcNew"))
        #expect(PersistenceManager.invitedRecord(saved)?.routeClock == 500)
    }

    @Test(arguments: ["session", "removal", "unavailable", "removed"])
    func cloudChangeDuringAuthenticationDefersStaleImport(change: String) async throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session()
        cloud.items[record.account] = record.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        let gate = TestGate()
        defer { gate.open() }
        var waiting = false
        let refresh = Task {
            await store.persistence.refreshInvitedSessions { _ in
                waiting = true
                await gate.wait()
                return InvitedSessionFixtures.principal()
            }
        }
        try await waitUntil("import authentication suspended") { waiting }
        switch change {
        case "session": cloud.items[record.account] = Data(#"{"v":3}"#.utf8)
        case "removal": cloud.items["invited-v2-r:future"] = Data(#"{"v":3}"#.utf8)
        case "removed":
            let removal = try InvitedSessionFixtures.removal()
            cloud.items[removal.account] = removal.data
        default: cloud.readFailure = errSecInteractionNotAllowed
        }
        gate.open()
        _ = await refresh.value
        #expect(store.persistence.loadConnections().isEmpty)
    }

    @Test func classifiedLegacyPersonCanBeForgottenWithoutCloudOrPublishedPayload() async throws {
        let cloud = MemorySyncedKeychain()
        cloud.readFailure = errSecInteractionNotAllowed
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        var local = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session()))
        local.principal = InvitedSessionFixtures.principal()
        local.invitedSyncPayload = nil
        #expect(store.persistence.saveConnectionsLocked([local]))
        #expect(store.persistence.deleteConnection(id: local.id))
        #expect(store.persistence.loadConnections().isEmpty)
        let removals = store.persistence.invitedJournal.removals
        #expect(removals.count == 1)
        cloud.readFailure = nil
        let stale = try InvitedSessionFixtures.session()
        cloud.items[stale.account] = stale.data
        let relaunched = store.relaunch()
        _ = await relaunched.refreshInvitedSessions { _ in
            Issue.record("Forgotten legacy credentials must not be authenticated again")
            return InvitedSessionFixtures.principal()
        }
        #expect(relaunched.loadConnections().isEmpty)
        #expect(relaunched.invitedJournal.removals == removals)
        for (key, data) in removals { #expect(cloud.items[key] == data) }
    }

    @Test(arguments: [false, true]) func unknownRoutePreservesClassifiedLegacyTunnel(explicitClear: Bool) async throws {
        let cloud = MemorySyncedKeychain()
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        var local = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session(changes: ["tcAddress": "tcOld", "tcUpdatedAt": 100])))
        local.principal = InvitedSessionFixtures.principal()
        local.invitedSyncPayload = nil
        #expect(store.persistence.saveConnectionsLocked([local]))
        let routeClock: Any = explicitClear ? 300 : NSNull()
        let remote = try InvitedSessionFixtures.session(changes: ["tcUpdatedAt": routeClock])
        cloud.items[remote.account] = remote.data
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let saved = try #require(store.relaunch().loadConnections().first)
        #expect(saved.server.tcAddress == (explicitClear ? nil : "tcOld"))
        #expect(PersistenceManager.invitedRecord(saved)?.pairedAt == 100)
    }
}
