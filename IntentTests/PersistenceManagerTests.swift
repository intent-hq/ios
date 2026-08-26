import Foundation
import Testing
@testable import Intent

/// Tests for PersistenceManager per-workspace screen persistence.
/// Uses a unique key prefix per test to avoid UserDefaults collisions.
@Suite(.serialized)
struct PersistenceManagerTests {

    // MARK: - Setup / Teardown helper

    /// Clean up UserDefaults keys used by PersistenceManager for workspace screens.
    private func cleanup(workspaceIds: [String]) {
        for id in workspaceIds {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: id)
        }
    }

    // MARK: - saveWorkspaceScreen / loadWorkspaceScreen round-trip

    @Test func roundTripConversationScreen() {
        let wsId = "test-ws-roundtrip-conv-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: wsId,
            agentId: "agent-42", agentName: "Builder",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded != nil)
        #expect(loaded?.screen == "conversation")
        #expect(loaded?.agentId == "agent-42")
        #expect(loaded?.agentName == "Builder")
        #expect(loaded?.workspaceId == wsId)
    }

    @Test func roundTripNoteScreen() {
        let wsId = "test-ws-roundtrip-note-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "note", workspaceId: wsId,
            agentId: nil, agentName: nil,
            noteId: "note-123", noteTitle: "My Note"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded != nil)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "note-123")
        #expect(loaded?.noteTitle == "My Note")
    }

    // MARK: - Load returns nil for unknown workspace

    @Test func loadReturnsNilForUnknownWorkspace() {
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(
            workspaceId: "nonexistent-ws-\(UUID().uuidString)"
        )
        #expect(loaded == nil)
    }

    // MARK: - clearWorkspaceScreen

    @Test func clearRemovesSavedScreen() {
        let wsId = "test-ws-clear-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: wsId,
            agentId: "a", agentName: "A",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) != nil)

        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) == nil)
    }

    // MARK: - Independent workspaces

    @Test func differentWorkspacesMaintainIndependentScreens() {
        let ws1 = "test-ws-indep-1-\(UUID().uuidString)"
        let ws2 = "test-ws-indep-2-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [ws1, ws2]) }

        let screen1 = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: ws1,
            agentId: "agent-A", agentName: "A",
            noteId: nil, noteTitle: nil
        )
        let screen2 = PersistenceManager.SavedScreen(
            screen: "note", workspaceId: ws2,
            agentId: nil, agentName: nil,
            noteId: "note-B", noteTitle: "B"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws1, screen: screen1)
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws2, screen: screen2)

        let loaded1 = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws1)
        let loaded2 = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws2)
        #expect(loaded1?.screen == "conversation")
        #expect(loaded1?.agentId == "agent-A")
        #expect(loaded2?.screen == "note")
        #expect(loaded2?.noteId == "note-B")
    }

    @Test func clearOneWorkspaceDoesNotAffectOther() {
        let ws1 = "test-ws-clear-one-\(UUID().uuidString)"
        let ws2 = "test-ws-clear-other-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [ws1, ws2]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: ws1,
            agentId: "a", agentName: "A",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws1, screen: screen)
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws2, screen: screen)

        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: ws1)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws1) == nil)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws2) != nil)
    }

    // MARK: - Overwrite

    @Test func savingOverwritesPreviousScreen() {
        let wsId = "test-ws-overwrite-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let first = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: wsId,
            agentId: "a1", agentName: "First",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: first)

        let second = PersistenceManager.SavedScreen(
            screen: "note", workspaceId: wsId,
            agentId: nil, agentName: nil,
            noteId: "n2", noteTitle: "Second"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: second)

        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "n2")
    }

    // MARK: - Concurrency regression test

    @Test func concurrentSavesDoNotCorruptSharedDictionary() async {
        let prefix = "test-ws-concurrent-\(UUID().uuidString)"
        let iterations = 100
        let workspaceIds = (0..<iterations).map { "\(prefix)-\($0)" }
        defer { cleanup(workspaceIds: workspaceIds) }

        // Submit many saves as independent tasks; the MainActor contract serializes mutations.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask { @MainActor in
                    let wsId = workspaceIds[i]
                    let screen = PersistenceManager.SavedScreen(
                        screen: "conversation",
                        workspaceId: wsId,
                        agentId: "agent-\(i)",
                        agentName: "Agent\(i)",
                        noteId: nil,
                        noteTitle: nil
                    )
                    PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
                }
            }
        }

        // Assert ALL entries are present and decodable (no lost updates)
        for i in 0..<iterations {
            let wsId = workspaceIds[i]
            let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
            #expect(loaded != nil, "Workspace \(wsId) missing (lost update)")
            #expect(loaded?.screen == "conversation")
            #expect(loaded?.agentId == "agent-\(i)")
            #expect(loaded?.agentName == "Agent\(i)")
        }

        // Also exercise workspaceTabs with the same multi-task scheduling.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask { @MainActor in
                    let wsId = workspaceIds[i]
                    PersistenceManager.shared.saveWorkspaceTab(workspaceId: wsId, tab: i % 3)
                }
            }
        }

        // Verify all tabs persisted correctly
        for i in 0..<iterations {
            let wsId = workspaceIds[i]
            let tab = PersistenceManager.shared.loadWorkspaceTab(workspaceId: wsId)
            #expect(tab == i % 3, "Workspace \(wsId) tab mismatch (lost update)")
        }
    }
}

/// In-memory `KeychainStorage` so connection-persistence tests are hermetic:
/// SecItem calls fail on headless CI simulators, and real Keychain state would
/// leak between runs.
final class InMemoryKeychainStorage: KeychainStorage, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{1F}\(account)" }

    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items[key(service, account)] = data
        return true
    }

    func load(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service, account)]
    }

    func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: key(service, account))
    }
}

/// Installs the in-memory Keychain backend exactly once per test process.
enum TestKeychainStorage {
    static let installed: Void = {
        PersistenceManager.shared.keychainStorage = InMemoryKeychainStorage()
    }()
}

/// Tests for the multi-connection persistence layer (Keychain-backed connection list,
/// active-connection pointer, legacy-pairing migration).
@Suite(.serialized)
struct ConnectionPersistenceTests {

    private let pm = PersistenceManager.shared

    init() {
        _ = TestKeychainStorage.installed
    }

    /// Remove all connection-related state (new blob, legacy entries, active pointer).
    private func resetConnectionState() {
        pm.deleteFromKeychain(account: pm.keychainAccountConnections)
        pm.deleteFromKeychain(account: pm.keychainAccountServer)
        pm.deleteFromKeychain(account: pm.keychainAccountToken)
        UserDefaults.standard.removeObject(forKey: pm.activeConnectionIdKey)
        UserDefaults.standard.removeObject(forKey: pm.serverKey)
    }

    private func makeServer(
        hosts: [String] = ["10.0.0.1"], port: Int = 4242, name: String = "daemon"
    ) -> PairedServer {
        PairedServer(hosts: hosts, port: port, name: name, pairedAt: Date())
    }

    // MARK: - Load / upsert

    @Test func loadConnectionsIsEmptyByDefault() {
        resetConnectionState()
        defer { resetConnectionState() }
        #expect(pm.loadConnections().isEmpty)
    }

    @Test func upsertInsertsAndRoundTrips() {
        resetConnectionState()
        defer { resetConnectionState() }

        let connection = StoredConnection(server: makeServer(), token: "tok-1")
        pm.upsertConnection(connection)

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first == connection)
        #expect(loaded.first?.displayName == "10.0.0.1:4242")
    }

    @Test func upsertDedupsSameHostSetAndPortPreservingId() {
        resetConnectionState()
        defer { resetConnectionState() }

        let original = StoredConnection(
            server: makeServer(hosts: ["a.local", "10.0.0.1"]),
            token: "tok-old",
            lastConnectedAt: Date(timeIntervalSince1970: 1000)
        )
        pm.upsertConnection(original)

        // Same host set (reordered) + port: updates in place, preserves id and lastConnectedAt.
        let updated = StoredConnection(
            server: makeServer(hosts: ["10.0.0.1", "a.local"]),
            token: "tok-new"
        )
        let stored = pm.upsertConnection(updated)

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(stored.id == original.id)
        #expect(loaded.first?.id == original.id)
        #expect(loaded.first?.token == "tok-new")
        #expect(loaded.first?.lastConnectedAt == original.lastConnectedAt)
    }

    @Test func upsertDifferentPortCreatesSeparateEntry() {
        resetConnectionState()
        defer { resetConnectionState() }

        pm.upsertConnection(StoredConnection(server: makeServer(port: 4242), token: "t1"))
        pm.upsertConnection(StoredConnection(server: makeServer(port: 4243), token: "t2"))
        #expect(pm.loadConnections().count == 2)
    }

    @Test func upsertOverlappingHostSetUpdatesInPlaceAndMergesHosts() {
        resetConnectionState()
        defer { resetConnectionState() }

        // Simulates a re-pair after the route refresh grew the stored host set:
        // upsert [h], grow to [h, ip] via updateConnectionHosts, then re-pair
        // with [h] again — must update the grown record, not insert a duplicate.
        let original = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["192.168.1.10"]), token: "tok-old"))
        pm.updateConnectionHosts(id: original.id, hosts: ["192.168.1.10", "10.0.0.5"])

        let stored = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["192.168.1.10"]), token: "tok-new"))

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(stored.id == original.id)
        #expect(loaded.first?.token == "tok-new")
        // Previously known routes are never dropped by a narrower re-pair.
        #expect(loaded.first?.server.hosts == ["192.168.1.10", "10.0.0.5"])
    }

    @Test func upsertDisjointHostSetSamePortCreatesSeparateEntry() {
        resetConnectionState()
        defer { resetConnectionState() }

        pm.upsertConnection(StoredConnection(server: makeServer(hosts: ["a.local"]), token: "t1"))
        pm.upsertConnection(StoredConnection(server: makeServer(hosts: ["b.local"]), token: "t2"))
        #expect(pm.loadConnections().count == 2)
    }

    @Test func mergeHostListsKeepsExistingFirstAndAppendsNew() {
        #expect(PersistenceManager.mergeHostLists(
            existing: ["nat.example.com", "192.168.1.10"],
            incoming: ["192.168.1.10", "10.0.0.5"])
            == ["nat.example.com", "192.168.1.10", "10.0.0.5"])
        #expect(PersistenceManager.mergeHostLists(existing: [], incoming: ["a"]) == ["a"])
        #expect(PersistenceManager.mergeHostLists(existing: ["a"], incoming: []) == ["a"])
    }

    // MARK: - updateConnectionHosts

    @Test func updateConnectionHostsGrowsHostSetWithoutDuplicating() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["192.168.1.10"]), token: "tok"))
        pm.updateConnectionHosts(id: stored.id, hosts: ["192.168.1.10", "10.0.0.5"])

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == stored.id)
        #expect(loaded.first?.server.hosts == ["192.168.1.10", "10.0.0.5"])
        // Everything else on the record is preserved.
        #expect(loaded.first?.token == "tok")
        #expect(loaded.first?.server.port == stored.server.port)
        #expect(loaded.first?.server.name == stored.server.name)
        #expect(loaded.first?.server.pairedAt == stored.server.pairedAt)
        #expect(loaded.first?.displayName == stored.displayName)
    }

    @Test func updateConnectionHostsPreservesCertFingerprint() {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = PairedServer(
            hosts: ["10.0.0.1"], port: 4242, name: "daemon",
            pairedAt: Date(), certFingerprint: "ab:cd")
        let stored = pm.upsertConnection(StoredConnection(server: server, token: "tok"))
        pm.updateConnectionHosts(id: stored.id, hosts: ["10.0.0.1", "10.0.0.2"])

        #expect(pm.loadConnections().first?.server.certFingerprint == "ab:cd")
    }

    @Test func updateConnectionHostsUnknownIdIsNoOp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = pm.upsertConnection(StoredConnection(server: makeServer(), token: "tok"))
        pm.updateConnectionHosts(id: UUID(), hosts: ["1.2.3.4"])

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server.hosts == stored.server.hosts)
    }

    // MARK: - updateConnectionDisplayName

    @Test func updateConnectionDisplayNameReplacesNamePreservingRecord() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = pm.upsertConnection(
            StoredConnection(server: makeServer(), token: "tok", displayName: "ugly.local-domain"))
        pm.updateConnectionDisplayName(id: stored.id, displayName: "Pretty Studio")

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == stored.id)
        #expect(loaded.first?.displayName == "Pretty Studio")
        // Everything else on the record is preserved.
        #expect(loaded.first?.token == "tok")
        #expect(loaded.first?.server == stored.server)
    }

    @Test func updateConnectionDisplayNameUnknownIdIsNoOp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = pm.upsertConnection(StoredConnection(server: makeServer(), token: "tok"))
        pm.updateConnectionDisplayName(id: UUID(), displayName: "Pretty Studio")

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.displayName == stored.displayName)
    }

    @Test func updateConnectionDisplayNameDoesNotAffectOtherRecords() {
        resetConnectionState()
        defer { resetConnectionState() }

        let a = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["a.local"], port: 1), token: "a"))
        let b = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["b.local"], port: 2), token: "b"))
        pm.updateConnectionDisplayName(id: a.id, displayName: "Pretty Studio")

        let loaded = pm.loadConnections()
        #expect(loaded.first { $0.id == a.id }?.displayName == "Pretty Studio")
        #expect(loaded.first { $0.id == b.id }?.displayName == b.displayName)
    }

    @Test func updateConnectionHostsDoesNotAffectOtherRecords() {
        resetConnectionState()
        defer { resetConnectionState() }

        let a = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["a.local"], port: 1), token: "a"))
        let b = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["b.local"], port: 2), token: "b"))
        pm.updateConnectionHosts(id: a.id, hosts: ["a.local", "10.0.0.9"])

        let loaded = pm.loadConnections()
        #expect(loaded.first { $0.id == a.id }?.server.hosts == ["a.local", "10.0.0.9"])
        #expect(loaded.first { $0.id == b.id }?.server.hosts == ["b.local"])
    }

    // MARK: - Delete

    @Test func deleteRemovesConnectionAndClearsActivePointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let a = pm.upsertConnection(StoredConnection(server: makeServer(port: 1), token: "a"))
        let b = pm.upsertConnection(StoredConnection(server: makeServer(port: 2), token: "b"))
        pm.setActiveConnection(id: a.id)

        pm.deleteConnection(id: a.id)
        #expect(pm.loadConnections().map(\.id) == [b.id])
        #expect(pm.activeConnection() == nil)

        // Deleting a non-active connection leaves the active pointer alone.
        pm.setActiveConnection(id: b.id)
        pm.deleteConnection(id: a.id)
        #expect(pm.activeConnection()?.id == b.id)
    }

    // MARK: - Active pointer

    @Test func activeConnectionRoundTrip() {
        resetConnectionState()
        defer { resetConnectionState() }

        #expect(pm.activeConnection() == nil)

        let a = pm.upsertConnection(StoredConnection(server: makeServer(port: 1), token: "a"))
        let b = pm.upsertConnection(StoredConnection(server: makeServer(port: 2), token: "b"))

        pm.setActiveConnection(id: a.id)
        #expect(pm.activeConnection()?.id == a.id)

        pm.setActiveConnection(id: b.id)
        #expect(pm.activeConnection()?.id == b.id)
    }

    @Test func touchLastConnectedUpdatesTimestamp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = pm.upsertConnection(StoredConnection(server: makeServer(), token: "t"))
        #expect(stored.lastConnectedAt == nil)

        let before = Date()
        pm.touchLastConnected(id: stored.id)
        let loaded = pm.loadConnections().first
        #expect(loaded?.lastConnectedAt != nil)
        if let touched = loaded?.lastConnectedAt {
            #expect(touched >= before)
        }
    }

    // MARK: - Migration

    @Test func migratesLegacyKeychainPairing() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["legacy.local"], port: 9999)
        let data = try JSONEncoder().encode(server)
        pm.saveDataToKeychain(data: data, account: pm.keychainAccountServer)
        pm.saveDataToKeychain(data: Data("legacy-token".utf8), account: pm.keychainAccountToken)

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server == server)
        #expect(loaded.first?.token == "legacy-token")
        #expect(pm.activeConnection()?.id == loaded.first?.id)

        // Legacy entries removed after successful migration.
        #expect(pm.loadDataFromKeychain(account: pm.keychainAccountServer) == nil)
        #expect(pm.loadDataFromKeychain(account: pm.keychainAccountToken) == nil)
    }

    @Test func migratesLegacyUserDefaultsPairing() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["defaults.local"], port: 8888)
        UserDefaults.standard.set(try JSONEncoder().encode(server), forKey: pm.serverKey)
        pm.saveDataToKeychain(data: Data("ud-token".utf8), account: pm.keychainAccountToken)

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server == server)
        #expect(loaded.first?.token == "ud-token")
        #expect(pm.activeConnection()?.id == loaded.first?.id)
        #expect(UserDefaults.standard.data(forKey: pm.serverKey) == nil)
    }

    @Test func migrationWithoutTokenIsNonDestructive() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["orphan.local"])
        let data = try JSONEncoder().encode(server)
        pm.saveDataToKeychain(data: data, account: pm.keychainAccountServer)

        // No token: nothing to migrate, legacy server entry must remain untouched.
        #expect(pm.loadConnections().isEmpty)
        #expect(pm.loadDataFromKeychain(account: pm.keychainAccountServer) == data)
    }

    @Test func migrationRunsOnlyOnce() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["once.local"])
        pm.saveDataToKeychain(data: try JSONEncoder().encode(server), account: pm.keychainAccountServer)
        pm.saveDataToKeychain(data: Data("tok".utf8), account: pm.keychainAccountToken)

        let first = pm.loadConnections()
        try #require(first.count == 1)

        // Deleting everything from the migrated list must not resurrect the legacy pairing.
        pm.deleteConnection(id: first[0].id)
        #expect(pm.loadConnections().isEmpty)
    }

    // MARK: - Synced-registry merge

    private func syncedRecord(
        host: String = "10.0.0.1", port: Int = 4242, fingerprint: String = "aa:bb",
        token: String = "tok-sync", updatedAt: Double = 100, deleted: Bool = false
    ) -> SyncedBackendRecord {
        SyncedBackendRecord(
            label: "Synced Mac", host: host, hosts: [host], port: port,
            fingerprint: fingerprint, hostname: nil, detectHosts: true,
            token: deleted ? "" : token, updatedAt: updatedAt,
            deleted: deleted, deletedAt: deleted ? updatedAt : nil)
    }

    @Test func mergeSyncedBackendsAddsAndPersistsNewRecords() {
        resetConnectionState()
        defer { resetConnectionState() }

        let outcome = pm.mergeSyncedBackends(records: [syncedRecord()])
        #expect(outcome.changed)
        #expect(outcome.addedIds.count == 1)
        #expect(!outcome.removedActiveConnection)

        let loaded = pm.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.token == "tok-sync")
        #expect(loaded.first?.server.certFingerprint == "aa:bb")
        #expect(loaded.first?.syncUpdatedAt == 100)
    }

    @Test func mergeSyncedBackendsTombstoneRemovesActiveAndClearsPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = pm.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.0.0.1"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok"))
        pm.setActiveConnection(id: stored.id)

        let outcome = pm.mergeSyncedBackends(
            records: [syncedRecord(updatedAt: 200, deleted: true)])
        #expect(outcome.removedIds == [stored.id])
        #expect(outcome.removedActiveConnection)
        #expect(pm.loadConnections().isEmpty)
        #expect(pm.activeConnection() == nil)
    }

    @Test func mergeSyncedBackendsTombstoneOnNonActiveKeepsPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = pm.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.0.0.1"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok"))
        let active = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["other.local"], port: 1), token: "o"))
        pm.setActiveConnection(id: active.id)

        let outcome = pm.mergeSyncedBackends(
            records: [syncedRecord(updatedAt: 200, deleted: true)])
        #expect(outcome.removedIds == [doomed.id])
        #expect(!outcome.removedActiveConnection)
        #expect(pm.activeConnection()?.id == active.id)
    }

    @Test func mergeSyncedBackendsNoChangeWritesNothing() {
        resetConnectionState()
        defer { resetConnectionState() }

        pm.mergeSyncedBackends(records: [syncedRecord(updatedAt: 100)])
        let before = pm.loadConnections()

        // Same clock again: no-op.
        let outcome = pm.mergeSyncedBackends(records: [syncedRecord(updatedAt: 100)])
        #expect(!outcome.changed)
        #expect(pm.loadConnections() == before)
    }

    // MARK: - Compatibility shims

    @Test func pairingShimsRoundTripOverConnectionsAPI() {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["shim.local"], port: 7777)
        pm.savePairing(server: server, token: "shim-token")

        let pairing = pm.loadPairing()
        #expect(pairing?.server == server)
        #expect(pairing?.token == "shim-token")
        #expect(pm.loadConnections().count == 1)

        // Re-pairing the same host:port does not create a duplicate.
        pm.savePairing(server: server, token: "shim-token-2")
        #expect(pm.loadConnections().count == 1)
        #expect(pm.loadPairing()?.token == "shim-token-2")

        // clearPairing forgets only the active connection.
        let other = pm.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["other.local"], port: 7778), token: "o")
        )
        pm.clearPairing()
        #expect(pm.loadPairing() == nil)
        #expect(pm.loadConnections().map(\.id) == [other.id])
    }
}

