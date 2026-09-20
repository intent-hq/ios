import Foundation
@testable import Intent
import Testing

extension ConnectionPersistenceTests {
    private var migrationPersistenceManager: PersistenceManager { PersistenceManager.shared }

    private func resetMigrationState() {
        migrationPersistenceManager.deleteFromKeychain(account: migrationPersistenceManager.keychainAccountConnections)
        migrationPersistenceManager.deleteFromKeychain(account: migrationPersistenceManager.keychainAccountServer)
        migrationPersistenceManager.deleteFromKeychain(account: migrationPersistenceManager.keychainAccountToken)
        UserDefaults.standard.removeObject(forKey: migrationPersistenceManager.activeConnectionIdKey)
        UserDefaults.standard.removeObject(forKey: migrationPersistenceManager.serverKey)
    }

    private func makeMigrationServer(
        hosts: [String] = ["10.0.0.1"],
        port: Int = 4242,
        name: String = "daemon"
    ) -> PairedServer {
        PairedServer(hosts: hosts, port: port, name: name, pairedAt: Date())
    }

    // MARK: - updateConnectionDisplayName

    @Test func updateConnectionDisplayNameReplacesNamePreservingRecord() {
        resetMigrationState()
        defer { resetMigrationState() }

        let stored = migrationPersistenceManager.upsertConnection(
            StoredConnection(server: makeMigrationServer(), token: "tok", displayName: "ugly.local-domain")
        )
        migrationPersistenceManager.updateConnectionDisplayName(id: stored.id, displayName: "Pretty Studio")

        let loaded = migrationPersistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == stored.id)
        #expect(loaded.first?.displayName == "Pretty Studio")
        // Everything else on the record is preserved.
        #expect(loaded.first?.token == "tok")
        #expect(loaded.first?.server == stored.server)
    }

    @Test func updateConnectionDisplayNameUnknownIdIsNoOp() {
        resetMigrationState()
        defer { resetMigrationState() }

        let stored = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(), token: "tok"))
        migrationPersistenceManager.updateConnectionDisplayName(id: UUID(), displayName: "Pretty Studio")

        let loaded = migrationPersistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.displayName == stored.displayName)
    }

    @Test func updateConnectionDisplayNameDoesNotAffectOtherRecords() {
        resetMigrationState()
        defer { resetMigrationState() }

        let firstConnection = migrationPersistenceManager.upsertConnection(
            StoredConnection(server: makeMigrationServer(hosts: ["a.local"], port: 1), token: "a")
        )
        let secondConnection = migrationPersistenceManager.upsertConnection(
            StoredConnection(server: makeMigrationServer(hosts: ["b.local"], port: 2), token: "b")
        )
        migrationPersistenceManager.updateConnectionDisplayName(id: firstConnection.id, displayName: "Pretty Studio")

        let loaded = migrationPersistenceManager.loadConnections()
        #expect(loaded.first { $0.id == firstConnection.id }?.displayName == "Pretty Studio")
        #expect(loaded.first { $0.id == secondConnection.id }?.displayName == secondConnection.displayName)
    }

    @Test func updateConnectionHostsDoesNotAffectOtherRecords() {
        resetMigrationState()
        defer { resetMigrationState() }

        let firstConnection = migrationPersistenceManager.upsertConnection(
            StoredConnection(server: makeMigrationServer(hosts: ["a.local"], port: 1), token: "a")
        )
        let secondConnection = migrationPersistenceManager.upsertConnection(
            StoredConnection(server: makeMigrationServer(hosts: ["b.local"], port: 2), token: "b")
        )
        migrationPersistenceManager.updateConnectionHosts(id: firstConnection.id, hosts: ["a.local", "10.0.0.9"])

        let loaded = migrationPersistenceManager.loadConnections()
        #expect(loaded.first { $0.id == firstConnection.id }?.server.hosts == ["a.local", "10.0.0.9"])
        #expect(loaded.first { $0.id == secondConnection.id }?.server.hosts == ["b.local"])
    }

    // MARK: - Delete

    @Test func deleteRemovesConnectionAndClearsActivePointer() {
        resetMigrationState()
        defer { resetMigrationState() }

        let firstConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 1), token: "a"))
        let secondConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 2), token: "b"))
        migrationPersistenceManager.setActiveConnection(id: firstConnection.id)

        migrationPersistenceManager.deleteConnection(id: firstConnection.id)
        #expect(migrationPersistenceManager.loadConnections().map(\.id) == [secondConnection.id])
        #expect(migrationPersistenceManager.activeConnection() == nil)

        // Deleting a non-active connection leaves the active pointer alone.
        migrationPersistenceManager.setActiveConnection(id: secondConnection.id)
        migrationPersistenceManager.deleteConnection(id: firstConnection.id)
        #expect(migrationPersistenceManager.activeConnection()?.id == secondConnection.id)
    }

    // MARK: - Active pointer

    @Test func activeConnectionRoundTrip() {
        resetMigrationState()
        defer { resetMigrationState() }

        #expect(migrationPersistenceManager.activeConnection() == nil)

        let firstConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 1), token: "a"))
        let secondConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 2), token: "b"))

        migrationPersistenceManager.setActiveConnection(id: firstConnection.id)
        #expect(migrationPersistenceManager.activeConnection()?.id == firstConnection.id)

        migrationPersistenceManager.setActiveConnection(id: secondConnection.id)
        #expect(migrationPersistenceManager.activeConnection()?.id == secondConnection.id)
    }

    @Test func touchLastConnectedUpdatesTimestamp() {
        resetMigrationState()
        defer { resetMigrationState() }

        let stored = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(), token: "t"))
        #expect(stored.lastConnectedAt == nil)

        let before = Date()
        migrationPersistenceManager.touchLastConnected(id: stored.id)
        let loaded = migrationPersistenceManager.loadConnections().first
        #expect(loaded?.lastConnectedAt != nil)
        if let touched = loaded?.lastConnectedAt {
            #expect(touched >= before)
        }
    }

    // MARK: - Launch-seed fallback (window model v2)

    @Test func lastUsedConnectionPrefersLastUsedPointer() {
        resetMigrationState()
        defer { resetMigrationState() }

        let firstConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 1), token: "a"))
        let secondConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 2), token: "b"))
        migrationPersistenceManager.touchLastConnected(id: secondConnection.id)
        migrationPersistenceManager.setActiveConnection(id: firstConnection.id)

        #expect(
            migrationPersistenceManager.lastUsedConnection()?.id == firstConnection.id,
            "The last-used pointer wins over recency when its record exists"
        )
    }

    @Test func lastUsedConnectionFallsBackToMostRecentlyConnected() {
        resetMigrationState()
        defer { resetMigrationState() }

        _ = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 1), token: "a"))
        let secondConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 2), token: "b"))
        let thirdConnection = migrationPersistenceManager.upsertConnection(StoredConnection(server: makeMigrationServer(port: 3), token: "c"))
        migrationPersistenceManager.touchLastConnected(id: thirdConnection.id)
        migrationPersistenceManager.touchLastConnected(id: secondConnection.id)

        #expect(
            migrationPersistenceManager.lastUsedConnection()?.id == secondConnection.id,
            "Without a pointer the most recently connected record wins"
        )
    }

    @Test func lastUsedConnectionIsNilWithoutSavedConnections() {
        resetMigrationState()
        defer { resetMigrationState() }

        #expect(migrationPersistenceManager.lastUsedConnection() == nil)
    }

    // MARK: - Migration

    @Test func migratesLegacyKeychainPairing() throws {
        resetMigrationState()
        defer { resetMigrationState() }

        let server = makeMigrationServer(hosts: ["legacy.local"], port: 9999)
        let data = try JSONEncoder().encode(server)
        migrationPersistenceManager.saveDataToKeychain(data: data, account: migrationPersistenceManager.keychainAccountServer)
        migrationPersistenceManager.saveDataToKeychain(data: Data("legacy-token".utf8), account: migrationPersistenceManager.keychainAccountToken)

        let loaded = migrationPersistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server == server)
        #expect(loaded.first?.token == "legacy-token")
        #expect(migrationPersistenceManager.activeConnection()?.id == loaded.first?.id)

        // Legacy entries removed after successful migration.
        #expect(migrationPersistenceManager.loadDataFromKeychain(account: migrationPersistenceManager.keychainAccountServer) == nil)
        #expect(migrationPersistenceManager.loadDataFromKeychain(account: migrationPersistenceManager.keychainAccountToken) == nil)
    }

    @Test func migratesLegacyUserDefaultsPairing() throws {
        resetMigrationState()
        defer { resetMigrationState() }

        let server = makeMigrationServer(hosts: ["defaults.local"], port: 8888)
        UserDefaults.standard.set(try JSONEncoder().encode(server), forKey: migrationPersistenceManager.serverKey)
        migrationPersistenceManager.saveDataToKeychain(data: Data("ud-token".utf8), account: migrationPersistenceManager.keychainAccountToken)

        let loaded = migrationPersistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server == server)
        #expect(loaded.first?.token == "ud-token")
        #expect(migrationPersistenceManager.activeConnection()?.id == loaded.first?.id)
        #expect(UserDefaults.standard.data(forKey: migrationPersistenceManager.serverKey) == nil)
    }

    @Test func migrationWithoutTokenIsNonDestructive() throws {
        resetMigrationState()
        defer { resetMigrationState() }

        let server = makeMigrationServer(hosts: ["orphan.local"])
        let data = try JSONEncoder().encode(server)
        migrationPersistenceManager.saveDataToKeychain(data: data, account: migrationPersistenceManager.keychainAccountServer)

        // No token: nothing to migrate, legacy server entry must remain untouched.
        #expect(migrationPersistenceManager.loadConnections().isEmpty)
        #expect(migrationPersistenceManager.loadDataFromKeychain(account: migrationPersistenceManager.keychainAccountServer) == data)
    }

    @Test func migrationRunsOnlyOnce() throws {
        resetMigrationState()
        defer { resetMigrationState() }

        let server = makeMigrationServer(hosts: ["once.local"])
        migrationPersistenceManager.saveDataToKeychain(data: try JSONEncoder().encode(server), account: migrationPersistenceManager.keychainAccountServer)
        migrationPersistenceManager.saveDataToKeychain(data: Data("tok".utf8), account: migrationPersistenceManager.keychainAccountToken)

        let first = migrationPersistenceManager.loadConnections()
        try #require(first.count == 1)

        // Deleting everything from the migrated list must not resurrect the legacy pairing.
        migrationPersistenceManager.deleteConnection(id: first[0].id)
        #expect(migrationPersistenceManager.loadConnections().isEmpty)
    }

    // MARK: - Synced-registry merge

    private func syncedRecord(
        host: String = "10.0.0.1",
        port: Int = 4242,
        fingerprint: String = "aa:bb",
        token: String = "tok-sync",
        updatedAt: Double = 100,
        deleted: Bool = false
    ) -> SyncedBackendRecord {
        SyncedBackendRecord(
            label: "Synced Mac",
            host: host,
            hosts: [host],
            port: port,
            fingerprint: fingerprint,
            hostname: nil,
            detectHosts: true,
            token: deleted ? "" : token,
            updatedAt: updatedAt,
            deleted: deleted,
            deletedAt: deleted ? updatedAt : nil
        )
    }

    @Test func mergeSyncedBackendsAddsAndPersistsNewRecords() {
        resetMigrationState()
        defer { resetMigrationState() }

        let outcome = migrationPersistenceManager.mergeSyncedBackends(records: [syncedRecord()])
        #expect(outcome.changed)
        #expect(outcome.addedIds.count == 1)
        #expect(!outcome.removedActiveConnection)

        let loaded = migrationPersistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.token == "tok-sync")
        #expect(loaded.first?.server.certFingerprint == "aa:bb")
        #expect(loaded.first?.syncUpdatedAt == 100)
    }

    @Test func mergeSyncedBackendsTombstoneRemovesActiveAndClearsPointer() {
        resetMigrationState()
        defer { resetMigrationState() }

        let stored = migrationPersistenceManager.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.0.0.1"],
                    port: 4242,
                    name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0),
                    certFingerprint: "aa:bb"
                ),
                token: "tok"
            )
        )
        migrationPersistenceManager.setActiveConnection(id: stored.id)

        let outcome = migrationPersistenceManager.mergeSyncedBackends(
            records: [syncedRecord(updatedAt: 200, deleted: true)]
        )
        #expect(outcome.removedIds == [stored.id])
        #expect(outcome.removedActiveConnection)
        #expect(migrationPersistenceManager.loadConnections().isEmpty)
        #expect(migrationPersistenceManager.activeConnection() == nil)
    }

    @Test func mergeSyncedBackendsTombstoneOnNonActiveKeepsPointer() {
        resetMigrationState()
        defer { resetMigrationState() }

        let doomed = migrationPersistenceManager.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.0.0.1"],
                    port: 4242,
                    name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0),
                    certFingerprint: "aa:bb"
                ),
                token: "tok"
            )
        )
        let active = migrationPersistenceManager.upsertConnection(
            StoredConnection(server: makeMigrationServer(hosts: ["other.local"], port: 1), token: "o")
        )
        migrationPersistenceManager.setActiveConnection(id: active.id)

        let outcome = migrationPersistenceManager.mergeSyncedBackends(
            records: [syncedRecord(updatedAt: 200, deleted: true)]
        )
        #expect(outcome.removedIds == [doomed.id])
        #expect(!outcome.removedActiveConnection)
        #expect(migrationPersistenceManager.activeConnection()?.id == active.id)
    }

    @Test func mergeSyncedBackendsNoChangeWritesNothing() {
        resetMigrationState()
        defer { resetMigrationState() }

        migrationPersistenceManager.mergeSyncedBackends(records: [syncedRecord(updatedAt: 100)])
        let before = migrationPersistenceManager.loadConnections()

        // Same clock again: no-op.
        let outcome = migrationPersistenceManager.mergeSyncedBackends(records: [syncedRecord(updatedAt: 100)])
        #expect(!outcome.changed)
        #expect(migrationPersistenceManager.loadConnections() == before)
    }

    // MARK: - Compatibility shims

    @Test func pairingShimsRoundTripOverConnectionsAPI() {
        resetMigrationState()
        defer { resetMigrationState() }

        let server = makeMigrationServer(hosts: ["shim.local"], port: 7777)
        migrationPersistenceManager.savePairing(server: server, token: "shim-token")

        let pairing = migrationPersistenceManager.loadPairing()
        #expect(pairing?.server == server)
        #expect(pairing?.token == "shim-token")
        #expect(migrationPersistenceManager.loadConnections().count == 1)

        // Re-pairing the same host:port does not create a duplicate.
        migrationPersistenceManager.savePairing(server: server, token: "shim-token-2")
        #expect(migrationPersistenceManager.loadConnections().count == 1)
        #expect(migrationPersistenceManager.loadPairing()?.token == "shim-token-2")

        // clearPairing forgets only the active connection.
        let other = migrationPersistenceManager.upsertConnection(
            StoredConnection(server: makeMigrationServer(hosts: ["other.local"], port: 7778), token: "o")
        )
        migrationPersistenceManager.clearPairing()
        #expect(migrationPersistenceManager.loadPairing() == nil)
        #expect(migrationPersistenceManager.loadConnections().map(\.id) == [other.id])
    }
}

/// Keyed last-screen persistence (window model v2: one slot per backend
/// connection) plus migration of the legacy single-slot screen. Each test
/// gets its own UserDefaults suite and in-memory keychain, removed again in
/// deinit.
@Suite(.serialized)
final class LastScreenPersistenceTests {
    private let persistenceManager: PersistenceManager
    private let suiteName: String

    init() throws {
        _ = TestKeychainStorage.installed
        suiteName = "LastScreenPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        persistenceManager = PersistenceManager(
            defaults: defaults,
            keychainStorage: InMemoryKeychainStorage()
        )
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeScreen(workspaceId: String) -> PersistenceManager.SavedScreen {
        PersistenceManager.SavedScreen(
            screen: "workspaceDetail",
            workspaceId: workspaceId,
            agentId: nil,
            agentName: nil,
            noteId: nil,
            noteTitle: nil
        )
    }

    @Test func roundTripIsKeyedPerConnection() {
        let firstConnection = UUID()
        let secondConnection = UUID()
        persistenceManager.saveLastScreen(makeScreen(workspaceId: "ws-a"), for: firstConnection)
        persistenceManager.saveLastScreen(makeScreen(workspaceId: "ws-b"), for: secondConnection)

        #expect(persistenceManager.loadLastScreen(for: firstConnection)?.workspaceId == "ws-a")
        #expect(persistenceManager.loadLastScreen(for: secondConnection)?.workspaceId == "ws-b")
        #expect(persistenceManager.loadLastScreen(for: UUID()) == nil)
    }

    @Test func clearRemovesOnlyThatConnectionsSlot() {
        let firstConnection = UUID()
        let secondConnection = UUID()
        persistenceManager.saveLastScreen(makeScreen(workspaceId: "ws-a"), for: firstConnection)
        persistenceManager.saveLastScreen(makeScreen(workspaceId: "ws-b"), for: secondConnection)

        persistenceManager.clearLastScreen(for: firstConnection)

        #expect(persistenceManager.loadLastScreen(for: firstConnection) == nil)
        #expect(persistenceManager.loadLastScreen(for: secondConnection)?.workspaceId == "ws-b")
    }

    @Test func legacySingleSlotMigratesToTheActiveConnection() {
        let active = persistenceManager.upsertConnection(StoredConnection(
            server: PairedServer(hosts: ["10.0.0.1"], port: 1, name: "a", pairedAt: Date()),
            token: "t"
        ))
        persistenceManager.setActiveConnection(id: active.id)
        persistenceManager.defaults.set("workspaceDetail", forKey: "lastScreen")
        persistenceManager.defaults.set("ws-legacy", forKey: "lastWorkspaceId")

        // A different connection must not adopt the legacy slot.
        #expect(persistenceManager.loadLastScreen(for: UUID()) == nil)

        // The connection that was active adopts the legacy slot once, and
        // the legacy keys are cleared so it cannot migrate twice.
        let migrated = persistenceManager.loadLastScreen(for: active.id)
        #expect(migrated?.screen == "workspaceDetail")
        #expect(migrated?.workspaceId == "ws-legacy")
        #expect(
            persistenceManager.defaults.string(forKey: "lastScreen") == nil,
            "The legacy slot must be cleared after migration"
        )
        #expect(
            persistenceManager.loadLastScreen(for: active.id)?.workspaceId == "ws-legacy",
            "The migrated screen must persist under the keyed slot"
        )
    }
}
