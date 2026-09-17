import Foundation
@testable import Intent
import Testing

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

    @Test func mergeHostListsDedupesCaseVariantsKeepingFirstSpelling() {
        // ios#341: DNS names are case-insensitive; a case-variant duplicate
        // must not become a second route. Existing spelling is preserved.
        #expect(PersistenceManager.mergeHostLists(
            existing: ["Mac.local", "[2001:DB8::1]"],
            incoming: ["mac.local", "MAC.LOCAL", "[2001:db8::1]", "Other.local", "other.local"]
        )
            == ["Mac.local", "[2001:DB8::1]", "Other.local"])
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
}
