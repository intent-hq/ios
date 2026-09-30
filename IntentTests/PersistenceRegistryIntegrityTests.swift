import Foundation
@testable import Intent
import Testing

@Suite("Undecodable connection registry", .serialized)
struct PersistenceRegistryIntegrityTests {
    private let manager = PersistenceManager.shared
    private let undecodableBlob = Data("{\"v\": 99, \"schema\": \"future\"}".utf8)

    init() { _ = TestKeychainStorage.installed }

    private func reset() {
        manager.deleteFromKeychain(account: manager.keychainAccountConnections)
        manager.deleteFromKeychain(account: manager.keychainAccountServer)
        manager.deleteFromKeychain(account: manager.keychainAccountToken)
        manager.defaults.removeObject(forKey: manager.activeConnectionIdKey)
    }

    private func server(host: String = "10.0.0.1") -> PairedServer {
        PairedServer(hosts: [host], port: 4242, name: "daemon", pairedAt: Date())
    }

    private func seed() {
        #expect(
            manager.saveDataToKeychain(
                data: undecodableBlob,
                account: manager.keychainAccountConnections
            )
        )
    }

    private func storedBlob() -> Data? {
        manager.loadDataFromKeychain(account: manager.keychainAccountConnections)
    }

    private func syncedRecord() -> SyncedBackendRecord {
        SyncedBackendRecord(
            label: "Synced Mac",
            host: "10.0.0.1",
            hosts: ["10.0.0.1"],
            port: 4242,
            fingerprint: "aa:bb",
            hostname: nil,
            detectHosts: true,
            token: "tok-sync",
            updatedAt: 100,
            deleted: false,
            deletedAt: nil
        )
    }

    @Test func absentBlobIsNotReportedAsUndecodable() {
        reset(); defer { reset() }
        #expect(!manager.isConnectionRegistryUndecodable())
        manager.upsertConnection(StoredConnection(server: server(), token: "tok"))
        #expect(!manager.isConnectionRegistryUndecodable())
    }

    @Test func undecodableBlobReadsAsEmptyButIsFlagged() {
        reset(); defer { reset() }; seed()
        #expect(manager.isConnectionRegistryUndecodable())
        #expect(manager.loadConnections().isEmpty)
        #expect(manager.activeConnection() == nil)
        #expect(storedBlob() == undecodableBlob)
    }

    @Test func upsertRefusesToOverwriteUndecodableBlob() {
        reset(); defer { reset() }; seed()
        let outcome = manager.upsertConnectionWithOutcome(
            StoredConnection(server: server(), token: "tok-new")
        )
        #expect(!outcome.persisted)
        #expect(outcome.registryUndecodable)
        #expect(storedBlob() == undecodableBlob)
        #expect(!manager.savePairing(server: server(host: "other.local"), token: "tok"))
        #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == nil)
    }

    @Test func syncedMergeRefusesToOverwriteUndecodableBlob() {
        reset(); defer { reset() }; seed()
        let staleActive = UUID()
        manager.defaults.set(staleActive.uuidString, forKey: manager.activeConnectionIdKey)
        let outcome = manager.mergeSyncedBackends(records: [syncedRecord()])
        #expect(outcome.registryUndecodable)
        #expect(!outcome.changed)
        #expect(!outcome.removedActiveConnection)
        #expect(storedBlob() == undecodableBlob)
        #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == staleActive.uuidString)
    }

    @Test func idKeyedWritesAndDeleteRefuseToTouchUndecodableBlob() {
        reset(); defer { reset() }; seed(); let id = UUID()
        #expect(!manager.updateConnectionHosts(id: id, hosts: ["x.local"]))
        #expect(!manager.updateConnectionTcAddress(id: id, tcAddress: "100.64.0.1"))
        #expect(!manager.updateConnectionDisplayName(id: id, displayName: "Renamed"))
        #expect(!manager.touchLastConnected(id: id))
        #expect(!manager.deleteConnection(id: id))
        #expect(storedBlob() == undecodableBlob)
    }

    @Test func legacyMigrationDoesNotReplaceUndecodableBlob() throws {
        reset(); defer { reset() }; seed()
        manager.saveDataToKeychain(
            data: try JSONEncoder().encode(server(host: "legacy.local")),
            account: manager.keychainAccountServer
        )
        manager.saveDataToKeychain(data: Data("legacy-tok".utf8), account: manager.keychainAccountToken)
        #expect(manager.loadConnections().isEmpty)
        #expect(storedBlob() == undecodableBlob)
        #expect(manager.loadDataFromKeychain(account: manager.keychainAccountServer) != nil)
        #expect(manager.loadStringFromKeychain(account: manager.keychainAccountToken) == "legacy-tok")
    }

    @Test func writesResumeOnceBlobIsDecodableAgain() {
        reset(); defer { reset() }; seed()
        #expect(
            !manager.upsertConnectionWithOutcome(
                StoredConnection(server: server(), token: "tok")
            ).persisted
        )
        manager.deleteFromKeychain(account: manager.keychainAccountConnections)
        #expect(!manager.isConnectionRegistryUndecodable())
        let outcome = manager.upsertConnectionWithOutcome(
            StoredConnection(server: server(), token: "tok")
        )
        #expect(outcome.persisted)
        #expect(!outcome.registryUndecodable)
        #expect(manager.loadConnections().count == 1)
    }
}
