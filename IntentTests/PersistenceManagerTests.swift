import Foundation
@testable import Intent
import Security
import Testing

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
            screen: "conversation",
            workspaceId: wsId,
            agentId: "agent-42",
            agentName: "Builder",
            noteId: nil,
            noteTitle: nil
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
            screen: "note",
            workspaceId: wsId,
            agentId: nil,
            agentName: nil,
            noteId: "note-123",
            noteTitle: "My Note"
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
            screen: "conversation",
            workspaceId: wsId,
            agentId: "a",
            agentName: "A",
            noteId: nil,
            noteTitle: nil
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
            screen: "conversation",
            workspaceId: ws1,
            agentId: "agent-A",
            agentName: "A",
            noteId: nil,
            noteTitle: nil
        )
        let screen2 = PersistenceManager.SavedScreen(
            screen: "note",
            workspaceId: ws2,
            agentId: nil,
            agentName: nil,
            noteId: "note-B",
            noteTitle: "B"
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
            screen: "conversation",
            workspaceId: ws1,
            agentId: "a",
            agentName: "A",
            noteId: nil,
            noteTitle: nil
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
            screen: "conversation",
            workspaceId: wsId,
            agentId: "a1",
            agentName: "First",
            noteId: nil,
            noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: first)

        let second = PersistenceManager.SavedScreen(
            screen: "note",
            workspaceId: wsId,
            agentId: nil,
            agentName: nil,
            noteId: "n2",
            noteTitle: "Second"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: second)

        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "n2")
    }

    // MARK: - MainActor serialization smoke test

    @Test func serializedMainActorSavesMaintainDataIntegrity() async {
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
    private var shouldFailSaves = false
    private let lock = NSLock()

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{1F}\(account)" }

    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shouldFailSaves else { return false }
        items[key(service, account)] = data
        return true
    }

    func setSaveFailure(_ shouldFail: Bool) {
        lock.lock()
        shouldFailSaves = shouldFail
        lock.unlock()
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

@Suite("Connection persistence failures", .serialized)
struct ConnectionPersistenceFailureTests {
    private func makePersistence(
        storage: InMemoryKeychainStorage
    ) throws -> (manager: PersistenceManager, suiteName: String) {
        let suiteName = "ConnectionPersistenceFailureTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (PersistenceManager(defaults: defaults, keychainStorage: storage), suiteName)
    }

    private func connection(token: String = "old") -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"],
                port: 4242,
                name: "daemon",
                pairedAt: Date(),
                certFingerprint: "aa:bb"
            ),
            token: token,
            displayName: "Original"
        )
    }

    @Test func failedRemovalPreservesRecordAndActivePointer() throws {
        let storage = InMemoryKeychainStorage()
        let setup = try makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let stored = setup.manager.upsertConnection(connection())
        setup.manager.setActiveConnection(id: stored.id)
        storage.setSaveFailure(true)

        #expect(!setup.manager.deleteConnection(id: stored.id))
        #expect(setup.manager.loadConnections() == [stored])
        #expect(setup.manager.activeConnection()?.id == stored.id)
    }

    @Test func failedSyncedMergePreservesRecordPointerAndReportsNoChange() throws {
        let storage = InMemoryKeychainStorage()
        let setup = try makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let stored = setup.manager.upsertConnection(connection())
        setup.manager.setActiveConnection(id: stored.id)
        storage.setSaveFailure(true)
        let tombstone = SyncedBackendRecord(
            label: "Synced Mac",
            host: "10.0.0.1",
            hosts: ["10.0.0.1"],
            port: 4242,
            fingerprint: "aa:bb",
            hostname: nil,
            detectHosts: true,
            token: "",
            updatedAt: Date().timeIntervalSince1970 * 1000,
            deleted: true,
            deletedAt: Date().timeIntervalSince1970 * 1000
        )

        let outcome = setup.manager.mergeSyncedBackends(records: [tombstone])

        #expect(!outcome.changed)
        #expect(setup.manager.loadConnections() == [stored])
        #expect(setup.manager.activeConnection()?.id == stored.id)
    }

    @Test func failedMetadataRefreshKeepsPreviouslySavedRecord() throws {
        let storage = InMemoryKeychainStorage()
        let setup = try makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let stored = setup.manager.upsertConnection(connection())
        storage.setSaveFailure(true)

        #expect(!setup.manager.updateConnectionDisplayName(
            id: stored.id,
            displayName: "Updated"
        ))
        #expect(setup.manager.loadConnections() == [stored])
    }
}

/// Installs the in-memory Keychain backend exactly once per test process.
enum TestKeychainStorage {
    static let installed: Void = {
        PersistenceManager.shared.keychainStorage = InMemoryKeychainStorage()
    }()
}

private final class FakeSecItemStore {
    struct Record: Equatable {
        var data: Data
        var accessibility: String
    }

    var items: [String: Record]
    var updateFailure: OSStatus?
    var addFailure: OSStatus?
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0
    private(set) var deleteCallCount = 0

    init(items: [String: Record] = [:]) {
        self.items = items
    }

    func record(service: String, account: String) -> Record? {
        items[key(service: service, account: account)]
    }

    func securityCalls() -> SecItemKeychainStorage.SecurityCalls {
        SecItemKeychainStorage.SecurityCalls(
            update: { [self] query, attributes in
                updateCallCount += 1
                if let updateFailure { return updateFailure }
                guard let key = key(from: query), var record = items[key] else {
                    return errSecItemNotFound
                }
                guard let data = attributes[kSecValueData as String] as? Data else {
                    return errSecParam
                }
                record.data = data
                items[key] = record
                return errSecSuccess
            },
            add: { [self] query in
                addCallCount += 1
                if let addFailure { return addFailure }
                guard let key = key(from: query), items[key] == nil,
                      let data = query[kSecValueData as String] as? Data,
                      let accessibility = query[kSecAttrAccessible as String] as? String else {
                    return errSecParam
                }
                items[key] = Record(data: data, accessibility: accessibility)
                return errSecSuccess
            },
            delete: { [self] query in
                deleteCallCount += 1
                guard let key = key(from: query) else { return errSecParam }
                items.removeValue(forKey: key)
                return errSecSuccess
            }
        )
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }

    private func key(from query: [String: Any]) -> String? {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return nil }
        return key(service: service, account: account)
    }
}

@Suite("SecItem Keychain storage")
struct SecItemKeychainStorageTests {
    private let service = "test.service"
    private let account = "test.account"
    private let original = FakeSecItemStore.Record(
        data: Data("old".utf8),
        accessibility: "existing-accessibility"
    )

    @Test func updateSucceedsWithoutDeleteOrAdd() {
        let fake = FakeSecItemStore(items: ["\(service)\u{1F}\(account)": original])
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        let replacement = Data("new".utf8)

        #expect(storage.save(data: replacement, service: service, account: account))
        #expect(
            fake.record(service: service, account: account)
                == .init(data: replacement, accessibility: original.accessibility)
        )
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 0)
        #expect(fake.deleteCallCount == 0)
    }

    @Test func updateFailurePreservesExistingRecordWithoutFallback() {
        let fake = FakeSecItemStore(items: ["\(service)\u{1F}\(account)": original])
        fake.updateFailure = errSecInteractionNotAllowed
        let storage = SecItemKeychainStorage(security: fake.securityCalls())

        #expect(!storage.save(data: Data("new".utf8), service: service, account: account))
        #expect(fake.record(service: service, account: account) == original)
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 0)
        #expect(fake.deleteCallCount == 0)
    }

    @Test func missingItemAddsWithExistingIdentityAndAccessibility() {
        let fake = FakeSecItemStore()
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        let data = Data("new".utf8)

        #expect(storage.save(data: data, service: service, account: account))
        #expect(
            fake.record(service: service, account: account)
                == .init(
                    data: data,
                    accessibility: kSecAttrAccessibleAfterFirstUnlock as String
                )
        )
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 1)
        #expect(fake.deleteCallCount == 0)
    }

    @Test func addFailureLeavesOtherEntriesUntouched() {
        let otherAccount = "other.account"
        let fake = FakeSecItemStore(items: ["\(service)\u{1F}\(otherAccount)": original])
        fake.addFailure = errSecNotAvailable
        let storage = SecItemKeychainStorage(security: fake.securityCalls())

        #expect(!storage.save(data: Data("new".utf8), service: service, account: account))
        #expect(fake.record(service: service, account: account) == nil)
        #expect(fake.record(service: service, account: otherAccount) == original)
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 1)
        #expect(fake.deleteCallCount == 0)
    }
}

/// Tests for the multi-connection persistence layer (Keychain-backed connection list,
/// active-connection pointer, legacy-pairing migration).
@Suite(.serialized)
struct ConnectionPersistenceTests {
    private let persistenceManager = PersistenceManager.shared

    init() {
        _ = TestKeychainStorage.installed
    }

    /// Remove all connection-related state (new blob, legacy entries, active pointer).
    private func resetConnectionState() {
        persistenceManager.deleteFromKeychain(account: persistenceManager.keychainAccountConnections)
        persistenceManager.deleteFromKeychain(account: persistenceManager.keychainAccountServer)
        persistenceManager.deleteFromKeychain(account: persistenceManager.keychainAccountToken)
        UserDefaults.standard.removeObject(forKey: persistenceManager.activeConnectionIdKey)
        UserDefaults.standard.removeObject(forKey: persistenceManager.serverKey)
    }

    private func makeServer(
        hosts: [String] = ["10.0.0.1"],
        port: Int = 4242,
        name: String = "daemon"
    ) -> PairedServer {
        PairedServer(hosts: hosts, port: port, name: name, pairedAt: Date())
    }

    // MARK: - Load / upsert

    @Test func loadConnectionsIsEmptyByDefault() {
        resetConnectionState()
        defer { resetConnectionState() }
        #expect(persistenceManager.loadConnections().isEmpty)
    }

    @Test func upsertInsertsAndRoundTrips() {
        resetConnectionState()
        defer { resetConnectionState() }

        let connection = StoredConnection(server: makeServer(), token: "tok-1")
        persistenceManager.upsertConnection(connection)

        let loaded = persistenceManager.loadConnections()
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
        persistenceManager.upsertConnection(original)

        // Same host set (reordered) + port: updates in place, preserves id and lastConnectedAt.
        let updated = StoredConnection(
            server: makeServer(hosts: ["10.0.0.1", "a.local"]),
            token: "tok-new"
        )
        let stored = persistenceManager.upsertConnection(updated)

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(stored.id == original.id)
        #expect(loaded.first?.id == original.id)
        #expect(loaded.first?.token == "tok-new")
        #expect(loaded.first?.lastConnectedAt == original.lastConnectedAt)
    }

    @Test func upsertDifferentPortCreatesSeparateEntry() {
        resetConnectionState()
        defer { resetConnectionState() }

        persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 4242), token: "t1"))
        persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 4243), token: "t2"))
        #expect(persistenceManager.loadConnections().count == 2)
    }

    @Test func upsertOverlappingHostSetUpdatesInPlaceAndMergesHosts() {
        resetConnectionState()
        defer { resetConnectionState() }

        // Simulates a re-pair after the route refresh grew the stored host set:
        // upsert [h], grow to [h, ip] via updateConnectionHosts, then re-pair
        // with [h] again — must update the grown record, not insert a duplicate.
        let original = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["192.168.1.10"]), token: "tok-old")
        )
        persistenceManager.updateConnectionHosts(id: original.id, hosts: ["192.168.1.10", "10.0.0.5"])

        let stored = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["192.168.1.10"]), token: "tok-new")
        )

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(stored.id == original.id)
        #expect(loaded.first?.token == "tok-new")
        // Previously known routes are never dropped by a narrower re-pair.
        #expect(loaded.first?.server.hosts == ["192.168.1.10", "10.0.0.5"])
    }

    @Test func upsertDisjointHostSetSamePortCreatesSeparateEntry() {
        resetConnectionState()
        defer { resetConnectionState() }

        persistenceManager.upsertConnection(StoredConnection(server: makeServer(hosts: ["a.local"]), token: "t1"))
        persistenceManager.upsertConnection(StoredConnection(server: makeServer(hosts: ["b.local"]), token: "t2"))
        #expect(persistenceManager.loadConnections().count == 2)
    }

    /// A tunnel-only re-pair (manual tc-address entry) carries no hosts, so
    /// host overlap can never match — the tcAddress is the record identity.
    /// Regression: without the tcAddress match key each re-pair inserted a
    /// duplicate record, including after the record had learned routes.
    @Test func upsertSameTcAddressUpdatesInPlaceDespiteDisjointHosts() {
        resetConnectionState()
        defer { resetConnectionState() }

        let original = persistenceManager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: [],
                port: 4242,
                name: "daemon",
                pairedAt: Date(),
                tcAddress: "tc-abc123"
            ),
            token: "tok-old"
        ))
        persistenceManager.updateConnectionHosts(id: original.id, hosts: ["10.0.0.1"])

        let stored = persistenceManager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: [],
                port: 4242,
                name: "daemon",
                pairedAt: Date(),
                tcAddress: "tc-abc123"
            ),
            token: "tok-new"
        ))

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(stored.id == original.id)
        #expect(loaded.first?.token == "tok-new")
        // Learned routes survive the tunnel-only re-pair.
        #expect(loaded.first?.server.hosts == ["10.0.0.1"])
        #expect(loaded.first?.server.tcAddress == "tc-abc123")
    }

    /// Records without a tcAddress never match on the tunnel key: two
    /// tunnel-less records with disjoint hosts stay separate (nil == nil must
    /// not collapse them).
    @Test func upsertNilTcAddressDoesNotMatchOnTunnelKey() {
        resetConnectionState()
        defer { resetConnectionState() }

        persistenceManager.upsertConnection(StoredConnection(server: makeServer(hosts: ["a.local"]), token: "t1"))
        persistenceManager.upsertConnection(StoredConnection(server: makeServer(hosts: ["b.local"]), token: "t2"))
        persistenceManager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: [],
                port: 4242,
                name: "daemon",
                pairedAt: Date(),
                tcAddress: "tc-abc123"
            ),
            token: "t3"
        ))
        #expect(persistenceManager.loadConnections().count == 3)
    }

    /// Same tc address on a different port is a different daemon listener —
    /// port stays part of the identity like it is for host matches.
    @Test func upsertSameTcAddressDifferentPortCreatesSeparateEntry() {
        resetConnectionState()
        defer { resetConnectionState() }

        persistenceManager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: [],
                port: 4242,
                name: "daemon",
                pairedAt: Date(),
                tcAddress: "tc-abc123"
            ),
            token: "t1"
        ))
        persistenceManager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: [],
                port: 4243,
                name: "daemon",
                pairedAt: Date(),
                tcAddress: "tc-abc123"
            ),
            token: "t2"
        ))
        #expect(persistenceManager.loadConnections().count == 2)
    }

    @Test func mergeHostListsKeepsExistingFirstAndAppendsNew() {
        #expect(PersistenceManager.mergeHostLists(
            existing: ["nat.example.com", "192.168.1.10"],
            incoming: ["192.168.1.10", "10.0.0.5"]
        )
            == ["nat.example.com", "192.168.1.10", "10.0.0.5"])
        #expect(PersistenceManager.mergeHostLists(existing: [], incoming: ["a"]) == ["a"])
        #expect(PersistenceManager.mergeHostLists(existing: ["a"], incoming: []) == ["a"])
    }

    // MARK: - updateConnectionHosts

    @Test func updateConnectionHostsGrowsHostSetWithoutDuplicating() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["192.168.1.10"]), token: "tok")
        )
        persistenceManager.updateConnectionHosts(id: stored.id, hosts: ["192.168.1.10", "10.0.0.5"])

        let loaded = persistenceManager.loadConnections()
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
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "daemon",
            pairedAt: Date(),
            certFingerprint: "ab:cd"
        )
        let stored = persistenceManager.upsertConnection(StoredConnection(server: server, token: "tok"))
        persistenceManager.updateConnectionHosts(id: stored.id, hosts: ["10.0.0.1", "10.0.0.2"])

        #expect(persistenceManager.loadConnections().first?.server.certFingerprint == "ab:cd")
    }

    @Test func updateConnectionHostsUnknownIdIsNoOp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistenceManager.upsertConnection(StoredConnection(server: makeServer(), token: "tok"))
        persistenceManager.updateConnectionHosts(id: UUID(), hosts: ["1.2.3.4"])

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server.hosts == stored.server.hosts)
    }

    @Test func updateConnectionHostsPreservesTcAddress() {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = PairedServer(
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "daemon",
            pairedAt: Date(),
            tcAddress: "tc-abc123"
        )
        let stored = persistenceManager.upsertConnection(StoredConnection(server: server, token: "tok"))
        persistenceManager.updateConnectionHosts(id: stored.id, hosts: ["10.0.0.1", "10.0.0.2"])

        #expect(persistenceManager.loadConnections().first?.server.tcAddress == "tc-abc123")
    }

    // MARK: - updateConnectionTcAddress

    @Test func updateConnectionTcAddressSetsAndReplaces() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistenceManager.upsertConnection(StoredConnection(server: makeServer(), token: "tok"))
        #expect(persistenceManager.loadConnections().first?.server.tcAddress == nil)

        persistenceManager.updateConnectionTcAddress(id: stored.id, tcAddress: "tc-first")
        #expect(persistenceManager.loadConnections().first?.server.tcAddress == "tc-first")

        persistenceManager.updateConnectionTcAddress(id: stored.id, tcAddress: "tc-second")
        let loaded = persistenceManager.loadConnections().first
        #expect(loaded?.server.tcAddress == "tc-second")
        #expect(loaded?.server.hosts == stored.server.hosts)
        #expect(loaded?.id == stored.id)
    }

    @Test func updateConnectionTcAddressUnknownIdIsNoOp() {
        resetConnectionState()
        defer { resetConnectionState() }

        persistenceManager.upsertConnection(StoredConnection(server: makeServer(), token: "tok"))
        persistenceManager.updateConnectionTcAddress(id: UUID(), tcAddress: "tc-x")
        #expect(persistenceManager.loadConnections().first?.server.tcAddress == nil)
    }

    /// A re-pair without a tunnel address (manual entry, QR from a daemon
    /// whose tunnel is down) must not drop the known address.
    @Test func upsertWithoutTcAddressPreservesExisting() {
        resetConnectionState()
        defer { resetConnectionState() }

        let withTc = PairedServer(
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "daemon",
            pairedAt: Date(),
            tcAddress: "tc-known"
        )
        persistenceManager.upsertConnection(StoredConnection(server: withTc, token: "tok-old"))

        persistenceManager.upsertConnection(StoredConnection(server: makeServer(), token: "tok-new"))
        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server.tcAddress == "tc-known")
        #expect(loaded.first?.token == "tok-new")
    }

    @Test func upsertWithTcAddressReplacesExisting() {
        resetConnectionState()
        defer { resetConnectionState() }

        let old = PairedServer(
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "daemon",
            pairedAt: Date(),
            tcAddress: "tc-old"
        )
        persistenceManager.upsertConnection(StoredConnection(server: old, token: "tok"))

        let new = PairedServer(
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "daemon",
            pairedAt: Date(),
            tcAddress: "tc-new"
        )
        persistenceManager.upsertConnection(StoredConnection(server: new, token: "tok"))
        #expect(persistenceManager.loadConnections().first?.server.tcAddress == "tc-new")
    }

    // MARK: - updateConnectionDisplayName

    @Test func updateConnectionDisplayNameReplacesNamePreservingRecord() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(), token: "tok", displayName: "ugly.local-domain")
        )
        persistenceManager.updateConnectionDisplayName(id: stored.id, displayName: "Pretty Studio")

        let loaded = persistenceManager.loadConnections()
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

        let stored = persistenceManager.upsertConnection(StoredConnection(server: makeServer(), token: "tok"))
        persistenceManager.updateConnectionDisplayName(id: UUID(), displayName: "Pretty Studio")

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.displayName == stored.displayName)
    }

    @Test func updateConnectionDisplayNameDoesNotAffectOtherRecords() {
        resetConnectionState()
        defer { resetConnectionState() }

        let firstConnection = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["a.local"], port: 1), token: "a")
        )
        let secondConnection = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["b.local"], port: 2), token: "b")
        )
        persistenceManager.updateConnectionDisplayName(id: firstConnection.id, displayName: "Pretty Studio")

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.first { $0.id == firstConnection.id }?.displayName == "Pretty Studio")
        #expect(loaded.first { $0.id == secondConnection.id }?.displayName == secondConnection.displayName)
    }

    @Test func updateConnectionHostsDoesNotAffectOtherRecords() {
        resetConnectionState()
        defer { resetConnectionState() }

        let firstConnection = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["a.local"], port: 1), token: "a")
        )
        let secondConnection = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["b.local"], port: 2), token: "b")
        )
        persistenceManager.updateConnectionHosts(id: firstConnection.id, hosts: ["a.local", "10.0.0.9"])

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.first { $0.id == firstConnection.id }?.server.hosts == ["a.local", "10.0.0.9"])
        #expect(loaded.first { $0.id == secondConnection.id }?.server.hosts == ["b.local"])
    }

    // MARK: - Delete

    @Test func deleteRemovesConnectionAndClearsActivePointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let firstConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 1), token: "a"))
        let secondConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 2), token: "b"))
        persistenceManager.setActiveConnection(id: firstConnection.id)

        persistenceManager.deleteConnection(id: firstConnection.id)
        #expect(persistenceManager.loadConnections().map(\.id) == [secondConnection.id])
        #expect(persistenceManager.activeConnection() == nil)

        // Deleting a non-active connection leaves the active pointer alone.
        persistenceManager.setActiveConnection(id: secondConnection.id)
        persistenceManager.deleteConnection(id: firstConnection.id)
        #expect(persistenceManager.activeConnection()?.id == secondConnection.id)
    }

    // MARK: - Active pointer

    @Test func activeConnectionRoundTrip() {
        resetConnectionState()
        defer { resetConnectionState() }

        #expect(persistenceManager.activeConnection() == nil)

        let firstConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 1), token: "a"))
        let secondConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 2), token: "b"))

        persistenceManager.setActiveConnection(id: firstConnection.id)
        #expect(persistenceManager.activeConnection()?.id == firstConnection.id)

        persistenceManager.setActiveConnection(id: secondConnection.id)
        #expect(persistenceManager.activeConnection()?.id == secondConnection.id)
    }

    @Test func touchLastConnectedUpdatesTimestamp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistenceManager.upsertConnection(StoredConnection(server: makeServer(), token: "t"))
        #expect(stored.lastConnectedAt == nil)

        let before = Date()
        persistenceManager.touchLastConnected(id: stored.id)
        let loaded = persistenceManager.loadConnections().first
        #expect(loaded?.lastConnectedAt != nil)
        if let touched = loaded?.lastConnectedAt {
            #expect(touched >= before)
        }
    }

    // MARK: - Launch-seed fallback (window model v2)

    @Test func lastUsedConnectionPrefersLastUsedPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let firstConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 1), token: "a"))
        let secondConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 2), token: "b"))
        persistenceManager.touchLastConnected(id: secondConnection.id)
        persistenceManager.setActiveConnection(id: firstConnection.id)

        #expect(
            persistenceManager.lastUsedConnection()?.id == firstConnection.id,
            "The last-used pointer wins over recency when its record exists"
        )
    }

    @Test func lastUsedConnectionFallsBackToMostRecentlyConnected() {
        resetConnectionState()
        defer { resetConnectionState() }

        _ = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 1), token: "a"))
        let secondConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 2), token: "b"))
        let thirdConnection = persistenceManager.upsertConnection(StoredConnection(server: makeServer(port: 3), token: "c"))
        persistenceManager.touchLastConnected(id: thirdConnection.id)
        persistenceManager.touchLastConnected(id: secondConnection.id)

        #expect(
            persistenceManager.lastUsedConnection()?.id == secondConnection.id,
            "Without a pointer the most recently connected record wins"
        )
    }

    @Test func lastUsedConnectionIsNilWithoutSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        #expect(persistenceManager.lastUsedConnection() == nil)
    }

    // MARK: - Migration

    @Test func migratesLegacyKeychainPairing() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["legacy.local"], port: 9999)
        let data = try JSONEncoder().encode(server)
        persistenceManager.saveDataToKeychain(data: data, account: persistenceManager.keychainAccountServer)
        persistenceManager.saveDataToKeychain(data: Data("legacy-token".utf8), account: persistenceManager.keychainAccountToken)

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server == server)
        #expect(loaded.first?.token == "legacy-token")
        #expect(persistenceManager.activeConnection()?.id == loaded.first?.id)

        // Legacy entries removed after successful migration.
        #expect(persistenceManager.loadDataFromKeychain(account: persistenceManager.keychainAccountServer) == nil)
        #expect(persistenceManager.loadDataFromKeychain(account: persistenceManager.keychainAccountToken) == nil)
    }

    @Test func migratesLegacyUserDefaultsPairing() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["defaults.local"], port: 8888)
        UserDefaults.standard.set(try JSONEncoder().encode(server), forKey: persistenceManager.serverKey)
        persistenceManager.saveDataToKeychain(data: Data("ud-token".utf8), account: persistenceManager.keychainAccountToken)

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.server == server)
        #expect(loaded.first?.token == "ud-token")
        #expect(persistenceManager.activeConnection()?.id == loaded.first?.id)
        #expect(UserDefaults.standard.data(forKey: persistenceManager.serverKey) == nil)
    }

    @Test func migrationWithoutTokenIsNonDestructive() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["orphan.local"])
        let data = try JSONEncoder().encode(server)
        persistenceManager.saveDataToKeychain(data: data, account: persistenceManager.keychainAccountServer)

        // No token: nothing to migrate, legacy server entry must remain untouched.
        #expect(persistenceManager.loadConnections().isEmpty)
        #expect(persistenceManager.loadDataFromKeychain(account: persistenceManager.keychainAccountServer) == data)
    }

    @Test func migrationRunsOnlyOnce() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["once.local"])
        persistenceManager.saveDataToKeychain(data: try JSONEncoder().encode(server), account: persistenceManager.keychainAccountServer)
        persistenceManager.saveDataToKeychain(data: Data("tok".utf8), account: persistenceManager.keychainAccountToken)

        let first = persistenceManager.loadConnections()
        try #require(first.count == 1)

        // Deleting everything from the migrated list must not resurrect the legacy pairing.
        persistenceManager.deleteConnection(id: first[0].id)
        #expect(persistenceManager.loadConnections().isEmpty)
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
        resetConnectionState()
        defer { resetConnectionState() }

        let outcome = persistenceManager.mergeSyncedBackends(records: [syncedRecord()])
        #expect(outcome.changed)
        #expect(outcome.addedIds.count == 1)
        #expect(!outcome.removedActiveConnection)

        let loaded = persistenceManager.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.token == "tok-sync")
        #expect(loaded.first?.server.certFingerprint == "aa:bb")
        #expect(loaded.first?.syncUpdatedAt == 100)
    }

    @Test func mergeSyncedBackendsTombstoneRemovesActiveAndClearsPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistenceManager.upsertConnection(
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
        persistenceManager.setActiveConnection(id: stored.id)

        let outcome = persistenceManager.mergeSyncedBackends(
            records: [syncedRecord(updatedAt: 200, deleted: true)]
        )
        #expect(outcome.removedIds == [stored.id])
        #expect(outcome.removedActiveConnection)
        #expect(persistenceManager.loadConnections().isEmpty)
        #expect(persistenceManager.activeConnection() == nil)
    }

    @Test func mergeSyncedBackendsTombstoneOnNonActiveKeepsPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistenceManager.upsertConnection(
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
        let active = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["other.local"], port: 1), token: "o")
        )
        persistenceManager.setActiveConnection(id: active.id)

        let outcome = persistenceManager.mergeSyncedBackends(
            records: [syncedRecord(updatedAt: 200, deleted: true)]
        )
        #expect(outcome.removedIds == [doomed.id])
        #expect(!outcome.removedActiveConnection)
        #expect(persistenceManager.activeConnection()?.id == active.id)
    }

    @Test func mergeSyncedBackendsNoChangeWritesNothing() {
        resetConnectionState()
        defer { resetConnectionState() }

        persistenceManager.mergeSyncedBackends(records: [syncedRecord(updatedAt: 100)])
        let before = persistenceManager.loadConnections()

        // Same clock again: no-op.
        let outcome = persistenceManager.mergeSyncedBackends(records: [syncedRecord(updatedAt: 100)])
        #expect(!outcome.changed)
        #expect(persistenceManager.loadConnections() == before)
    }

    // MARK: - Compatibility shims

    @Test func pairingShimsRoundTripOverConnectionsAPI() {
        resetConnectionState()
        defer { resetConnectionState() }

        let server = makeServer(hosts: ["shim.local"], port: 7777)
        persistenceManager.savePairing(server: server, token: "shim-token")

        let pairing = persistenceManager.loadPairing()
        #expect(pairing?.server == server)
        #expect(pairing?.token == "shim-token")
        #expect(persistenceManager.loadConnections().count == 1)

        // Re-pairing the same host:port does not create a duplicate.
        persistenceManager.savePairing(server: server, token: "shim-token-2")
        #expect(persistenceManager.loadConnections().count == 1)
        #expect(persistenceManager.loadPairing()?.token == "shim-token-2")

        // clearPairing forgets only the active connection.
        let other = persistenceManager.upsertConnection(
            StoredConnection(server: makeServer(hosts: ["other.local"], port: 7778), token: "o")
        )
        persistenceManager.clearPairing()
        #expect(persistenceManager.loadPairing() == nil)
        #expect(persistenceManager.loadConnections().map(\.id) == [other.id])
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
