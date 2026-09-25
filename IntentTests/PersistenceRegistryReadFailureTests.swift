import Foundation
@testable import Intent
import Security
import Testing

/// Faults are injected beneath SecItemKeychainStorage, not by mocking the
/// persistence result: a read can fail while the write backend remains usable.
@Suite("Saved connection read safety")
final class PersistenceRegistryReadFailureTests {
    private let fake = FakeSecItemStore()
    private let manager: PersistenceManager
    private let suiteName: String

    init() throws {
        suiteName = "PersistenceRegistryReadFailureTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        manager = PersistenceManager(
            defaults: defaults,
            keychainStorage: SecItemKeychainStorage(security: fake.securityCalls())
        )
    }

    deinit { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    private func connection(host: String = "saved.local", fingerprint: String = "aa:bb") -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: [host],
                port: 4242,
                name: "Fixture",
                pairedAt: Date(timeIntervalSince1970: 0),
                certFingerprint: fingerprint
            ),
            token: "fixture-token"
        )
    }

    private func record(deleted: Bool = false) -> SyncedBackendRecord {
        SyncedBackendRecord(
            label: "Synced fixture",
            host: "saved.local",
            hosts: ["saved.local"],
            port: 4242,
            fingerprint: "aa:bb",
            hostname: nil,
            detectHosts: true,
            token: "fixture-token",
            updatedAt: 100,
            deleted: deleted,
            deletedAt: deleted ? 100 : nil
        )
    }

    private func seedLegacy() throws {
        let data = try JSONEncoder().encode(connection(host: "legacy.local").server)
        #expect(manager.saveDataToKeychain(data: data, account: manager.keychainAccountServer))
        #expect(manager.saveDataToKeychain(data: Data("legacy-fixture".utf8), account: manager.keychainAccountToken))
        manager.defaults.set(data, forKey: manager.serverKey)
    }

    @Test func loadOutcomeDistinguishesMissingEmptyMalformedAndUnavailable() {
        #expect(manager.loadConnectionsWithOutcome() == .missing)
        #expect(manager.saveDataToKeychain(data: Data("[]".utf8), account: manager.keychainAccountConnections))
        #expect(manager.loadConnectionsWithOutcome() == .loaded([]))
        #expect(manager.saveDataToKeychain(data: Data("invalid".utf8), account: manager.keychainAccountConnections))
        #expect(manager.loadConnectionsWithOutcome() == .failed(.malformed))
        fake.readFailures[manager.keychainAccountConnections] = errSecNotAvailable
        #expect(manager.loadConnectionsWithOutcome() == .failed(.unavailable(errSecNotAvailable)))
    }

    @Test(arguments: [false, true])
    func failedRegistryReadBlocksAllMutationsAndSelection(malformed: Bool) throws {
        let stored = manager.upsertConnection(connection())
        #expect(manager.setActiveConnection(id: stored.id))
        try seedLegacy()
        if malformed {
            #expect(manager.saveDataToKeychain(data: Data("invalid".utf8), account: manager.keychainAccountConnections))
        } else {
            fake.readFailures[manager.keychainAccountConnections] = errSecInteractionNotAllowed
        }
        let before = fake.items
        let writes = fake.updateCallCount
        let adds = fake.addCallCount
        let error: ConnectionRegistryReadError = malformed ? .malformed : .unavailable(errSecInteractionNotAllowed)

        let upsert = manager.upsertConnectionWithOutcome(connection(host: "new.local"))
        #expect(!upsert.persisted)
        #expect(upsert.registryReadError == error)
        #expect(!manager.savePairing(server: connection().server, token: "replacement-fixture"))
        for deleted in [false, true] {
            let merge = manager.mergeSyncedBackends(records: [record(deleted: deleted)])
            #expect(!merge.changed)
            #expect(!merge.removedActiveConnection)
            #expect(merge.registryReadError == error)
        }
        #expect(!manager.updateConnectionHosts(id: stored.id, hosts: ["changed.local"]))
        #expect(!manager.updateConnectionTcAddress(id: stored.id, tcAddress: "100.64.0.1"))
        #expect(!manager.updateConnectionDisplayName(id: stored.id, displayName: "Changed"))
        #expect(!manager.touchLastConnected(id: stored.id))
        #expect(!manager.deleteConnection(id: stored.id))
        #expect(!manager.deleteConnection(id: UUID()))
        #expect(!manager.clearPairing())
        #expect(!manager.setActiveConnection(id: UUID()))
        #expect(fake.items == before)
        #expect(fake.updateCallCount == writes)
        #expect(fake.addCallCount == adds)
        #expect(fake.deleteCallCount == 0)
        #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == stored.id.uuidString)
        #expect(manager.defaults.data(forKey: manager.serverKey) != nil)
        if !malformed {
            fake.readFailures = [:]
            #expect(manager.mergeSyncedBackends(records: [record(deleted: true)]).removedActiveConnection)
            #expect(manager.loadConnections().isEmpty)
            #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == nil)
        }
    }

    @Test func transientReadFailureStopsOperationAndExplicitRetryPreservesRecords() {
        let stored = manager.upsertConnection(connection())
        #expect(manager.setActiveConnection(id: stored.id))
        let incoming = connection(host: "new.local", fingerprint: "cc:dd")
        let before = fake.items
        let writes = fake.updateCallCount
        fake.nextReadFailures[manager.keychainAccountConnections] = errSecNotAvailable
        #expect(!manager.upsertConnectionWithOutcome(incoming).persisted)
        #expect(fake.items == before)
        #expect(fake.updateCallCount == writes)

        #expect(manager.upsertConnectionWithOutcome(incoming).persisted)
        #expect(manager.loadConnections() == [stored, incoming])
        #expect(manager.activeConnection()?.id == stored.id)
    }

    @Test func missingLegacyItemsRemainAUsableEmptyBaseline() {
        #expect(manager.deleteConnection(id: UUID()))
        #expect(manager.clearPairing())
        let incoming = connection()
        #expect(manager.upsertConnectionWithOutcome(incoming).persisted)
        #expect(manager.loadConnectionsWithOutcome() == .loaded([incoming]))
        #expect(manager.setActiveConnection(id: incoming.id))
        #expect(manager.deleteConnection(id: incoming.id))
        #expect(manager.loadConnectionsWithOutcome() == .loaded([]))
        #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == nil)
    }

    @Test func syncMergeRetriesAgainstPreservedRegistryRatherThanEmptyBaseline() {
        let stored = manager.upsertConnection(connection(host: "other.local", fingerprint: "cc:dd"))
        #expect(manager.setActiveConnection(id: stored.id))
        let before = fake.items
        let writes = fake.updateCallCount
        fake.nextReadFailures[manager.keychainAccountConnections] = errSecNotAvailable
        #expect(manager.mergeSyncedBackends(records: [record()]).registryReadError == .unavailable(errSecNotAvailable))
        #expect(fake.items == before)
        #expect(fake.updateCallCount == writes)

        let outcome = manager.mergeSyncedBackends(records: [record()])
        #expect(outcome.changed)
        #expect(outcome.registryReadError == nil)
        #expect(manager.loadConnections().contains(stored))
        #expect(manager.loadConnections().count == 2)
        #expect(manager.activeConnection()?.id == stored.id)
    }

    @Test(arguments: ["serverInfo", "apiToken"])
    func legacyReadFailureBlocksMigrationFallbackAndWrites(account: String) throws {
        try seedLegacy()
        let previousActive = UUID().uuidString
        manager.defaults.set(previousActive, forKey: manager.activeConnectionIdKey)
        fake.readFailures[account] = errSecInteractionNotAllowed
        let before = fake.items
        let writes = fake.updateCallCount
        #expect(manager.loadConnectionsWithOutcome() == .failed(.unavailable(errSecInteractionNotAllowed)))
        #expect(!manager.upsertConnectionWithOutcome(connection()).persisted)
        #expect(manager.mergeSyncedBackends(records: [record()]).registryReadError == .unavailable(errSecInteractionNotAllowed))
        #expect(!manager.deleteConnection(id: UUID()))
        #expect(!manager.clearPairing())
        #expect(!manager.setActiveConnection(id: UUID()))
        #expect(fake.items == before)
        #expect(fake.updateCallCount == writes)
        #expect(fake.deleteCallCount == 0)
        #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == previousActive)
        #expect(manager.defaults.data(forKey: manager.serverKey) != nil)

        fake.readFailures = [:]
        let migrated = manager.loadConnectionsWithOutcome()
        #expect(migrated.error == nil)
        #expect(migrated.connections?.first?.server.hosts == ["legacy.local"])
        #expect(fake.deleteCallCount == 2)
        #expect(manager.defaults.data(forKey: manager.serverKey) == nil)
    }

    @Test(arguments: ["serverInfo", "apiToken"])
    func malformedLegacyDataIsNotOverwrittenOrErased(account: String) throws {
        try seedLegacy()
        #expect(manager.saveDataToKeychain(data: Data([0xFF]), account: account))
        let before = fake.items
        let writes = fake.updateCallCount
        #expect(manager.loadConnectionsWithOutcome() == .failed(.malformed))
        #expect(!manager.upsertConnectionWithOutcome(connection()).persisted)
        #expect(!manager.clearPairing())
        #expect(fake.items == before)
        #expect(fake.updateCallCount == writes)
        #expect(fake.deleteCallCount == 0)
        #expect(manager.defaults.data(forKey: manager.serverKey) != nil)
    }

    @Test func failedMigrationSaveCannotFallThroughToAnotherWrite() throws {
        try seedLegacy()
        let previousActive = UUID().uuidString
        manager.defaults.set(previousActive, forKey: manager.activeConnectionIdKey)
        let before = fake.items
        let writes = fake.updateCallCount
        fake.nextUpdateFailure = errSecNotAvailable
        let outcome = manager.upsertConnectionWithOutcome(connection())
        #expect(!outcome.persisted)
        #expect(outcome.registryReadError == .migrationSaveFailed)
        #expect(fake.items == before)
        #expect(fake.updateCallCount == writes + 1)
        #expect(fake.deleteCallCount == 0)
        #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == previousActive)
        #expect(manager.defaults.data(forKey: manager.serverKey) != nil)
    }

    @Test func clearPairingChecksLegacyReadsBeforeDeletingActiveRecord() throws {
        let stored = manager.upsertConnection(connection())
        #expect(manager.setActiveConnection(id: stored.id))
        try seedLegacy()
        let before = fake.items
        fake.readFailures[manager.keychainAccountToken] = errSecNotAvailable
        #expect(!manager.clearPairing())
        #expect(fake.items == before)
        #expect(fake.deleteCallCount == 0)
        #expect(manager.activeConnection()?.id == stored.id)
    }
}
