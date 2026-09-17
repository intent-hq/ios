import Foundation

struct ConnectionUpsertOutcome {
    let connection: StoredConnection
    let persisted: Bool
    let registryUndecodable: Bool
}

class PersistenceManager {
    static let shared = DemoMode.isEnabled ? PersistenceManager.ephemeral() : PersistenceManager()

    static func ephemeral() -> PersistenceManager {
        let suiteName = "com.intent.companion.demo-data"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return PersistenceManager(defaults: defaults, keychainStorage: EphemeralKeychainStorage())
    }

    let serverKey = "pairedServer"
    private let keychainService = "com.intent.companion"
    let keychainAccountToken = "apiToken"
    let keychainAccountServer = "serverInfo"
    let keychainAccountConnections = "connections"
    let activeConnectionIdKey = "activeConnectionId"

    /// Backing store for non-secret values. Tests inject a private suite so
    /// persisted state (navigation, drafts, active connection id) can't leak
    /// between tests or into the real app container.
    let defaults: UserDefaults

    /// Backend for Keychain-stored values. Tests substitute an in-memory
    /// implementation (SecItem calls fail in headless CI simulators).
    var keychainStorage: KeychainStorage

    init(
        defaults: UserDefaults = .standard,
        keychainStorage: KeychainStorage = SecItemKeychainStorage()
    ) {
        self.defaults = defaults
        self.keychainStorage = keychainStorage
    }
}

extension PersistenceManager {
    // MARK: - Connections

    func loadConnections() -> [StoredConnection] {
        migrateLegacyPairingIfNeeded()
        return loadConnectionsLocked()
    }

    func isConnectionRegistryUndecodable() -> Bool {
        readConnectionsLocked() == nil
    }

    /// Inserts the connection, or updates the existing entry in place (preserving its
    /// id) when one at the same port shares at least one host or carries the same
    /// tailcat tunnel address. Returns the stored value.
    ///
    /// Overlap (not set equality) is the match key because the post-connect route
    /// refresh grows stored host sets over time: a re-pair of the same daemon via a
    /// single manually entered host (or a QR payload with a different host list) must
    /// still update the grown record in place instead of inserting a duplicate. On a
    /// match, the existing record's hosts are kept (in order) and new hosts appended,
    /// so previously known routes are never dropped by a narrower re-pair.
    ///
    /// A matching tcAddress is an equally valid identity: a manual tunnel-only
    /// re-pair carries no hosts at all (its host set is disjoint with every
    /// record), so without this key each re-pair of the same tc address would
    /// insert a duplicate record.
    @discardableResult
    func upsertConnection(_ connection: StoredConnection) -> StoredConnection {
        upsertConnectionWithOutcome(connection).connection
    }

    /// Upserts a connection and reports whether the resulting registry was
    /// durably saved. Callers that publish pairing success must use this form.
    @discardableResult
    func upsertConnectionWithOutcome(
        _ connection: StoredConnection
    ) -> ConnectionUpsertOutcome {
        migrateLegacyPairingIfNeeded()
        guard var connections = readConnectionsLocked() else {
            return ConnectionUpsertOutcome(
                connection: connection,
                persisted: false,
                registryUndecodable: true
            )
        }
        let stored: StoredConnection
        if let index = connections.firstIndex(where: { storedConnection in
            storedConnection.server.port == connection.server.port
                && (!Set(storedConnection.server.hosts).isDisjoint(with: connection.server.hosts)
                    || (connection.server.tcAddress != nil
                        && storedConnection.server.tcAddress == connection.server.tcAddress))
        }) {
            let existing = connections[index]
            let server = connection.server
            stored = StoredConnection(
                id: existing.id,
                server: PairedServer(
                    hosts: Self.mergeHostLists(
                        existing: existing.server.hosts,
                        incoming: server.hosts
                    ),
                    port: server.port,
                    name: server.name,
                    pairedAt: server.pairedAt,
                    certFingerprint: server.certFingerprint,
                    // A re-pair without a tunnel address (manual entry, QR
                    // from a daemon whose tunnel is down) must not drop the
                    // known one; the post-connect refresh keeps it current.
                    tcAddress: server.tcAddress ?? existing.server.tcAddress
                ),
                token: connection.token,
                displayName: connection.displayName,
                lastConnectedAt: connection.lastConnectedAt ?? existing.lastConnectedAt,
                // The LWW clock survives a re-pair: the record is still the
                // registry copy it was last synced from (write-back is the
                // push path's job, not upsert's).
                syncUpdatedAt: connection.syncUpdatedAt ?? existing.syncUpdatedAt
            )
            connections[index] = stored
        } else {
            stored = connection
            connections.append(stored)
        }
        return ConnectionUpsertOutcome(
            connection: stored,
            persisted: saveConnectionsLocked(connections),
            registryUndecodable: false
        )
    }

    /// Existing hosts keep their order and are never dropped; incoming hosts not
    /// already present are appended, deduped case-insensitively (DNS names and
    /// IPv6 hex are case-insensitive — ios#341), keeping the first spelling seen.
    static func mergeHostLists(existing: [String], incoming: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing.map(SyncedBackendConnectionMerge.normalizeHost))
        for host in incoming {
            let key = SyncedBackendConnectionMerge.normalizeHost(host)
            guard !seen.contains(key) else { continue }
            merged.append(host)
            seen.insert(key)
        }
        return merged
    }

    /// Replaces the stored host list of the connection with the given id,
    /// preserving the record identity. Unlike `upsertConnection` (which matches
    /// by host set + port and would treat a grown host set as a new pairing),
    /// this never inserts or duplicates records. No-op when the id is unknown.
    @discardableResult
    func updateConnectionHosts(id: UUID, hosts: [String]) -> Bool {
        migrateLegacyPairingIfNeeded()
        guard var connections = readConnectionsLocked() else { return false }
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return false }
        let server = connections[index].server
        connections[index].server = PairedServer(
            hosts: hosts,
            port: server.port,
            name: server.name,
            pairedAt: server.pairedAt,
            certFingerprint: server.certFingerprint,
            tcAddress: server.tcAddress
        )
        return saveConnectionsLocked(connections)
    }

    /// Replaces the stored tailcat tunnel address of the connection with the
    /// given id, preserving the record identity. Used by the post-connect
    /// refresh when `system.status` reports a `tcAddress`. No-op when the id
    /// is unknown.
    @discardableResult
    func updateConnectionTcAddress(id: UUID, tcAddress: String) -> Bool {
        migrateLegacyPairingIfNeeded()
        guard var connections = readConnectionsLocked() else { return false }
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return false }
        let server = connections[index].server
        connections[index].server = PairedServer(
            hosts: server.hosts,
            port: server.port,
            name: server.name,
            pairedAt: server.pairedAt,
            certFingerprint: server.certFingerprint,
            tcAddress: tcAddress
        )
        return saveConnectionsLocked(connections)
    }

    /// Replaces the stored display name of the connection with the given id,
    /// preserving the record identity. Used by the post-connect refresh so
    /// records saved before the daemon reported a pretty hostname heal on the
    /// next successful connect. No-op when the id is unknown.
    @discardableResult
    func updateConnectionDisplayName(id: UUID, displayName: String) -> Bool {
        migrateLegacyPairingIfNeeded()
        guard var connections = readConnectionsLocked() else { return false }
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return false }
        connections[index].displayName = displayName
        return saveConnectionsLocked(connections)
    }

    @discardableResult
    func deleteConnection(id: UUID) -> Bool {
        migrateLegacyPairingIfNeeded()
        guard var connections = readConnectionsLocked() else { return false }
        guard connections.contains(where: { $0.id == id }) else { return true }
        connections.removeAll { $0.id == id }
        guard saveConnectionsLocked(connections) else { return false }
        if activeConnectionIdLocked() == id {
            defaults.removeObject(forKey: activeConnectionIdKey)
        }
        return true
    }

    /// The last-used backend pointer (window model v2: no longer a
    /// navigation concept — it only seeds which backend a fresh window
    /// binds to at launch).
    func activeConnection() -> StoredConnection? {
        migrateLegacyPairingIfNeeded()
        guard let id = activeConnectionIdLocked() else { return nil }
        return loadConnectionsLocked().first { $0.id == id }
    }

    func setActiveConnection(id: UUID) {
        defaults.set(id.uuidString, forKey: activeConnectionIdKey)
    }

    /// The backend a fresh window binds to at launch when system restoration
    /// supplied none: the last-used pointer when its record still exists,
    /// else the most recently connected saved record.
    func lastUsedConnection() -> StoredConnection? {
        if let active = activeConnection() { return active }
        return loadConnections().max { lhs, rhs in
            (lhs.lastConnectedAt ?? .distantPast) < (rhs.lastConnectedAt ?? .distantPast)
        }
    }

    @discardableResult
    func touchLastConnected(id: UUID) -> Bool {
        migrateLegacyPairingIfNeeded()
        guard var connections = readConnectionsLocked() else { return false }
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return false }
        connections[index].lastConnectedAt = Date()
        return saveConnectionsLocked(connections)
    }

    /// Merges the iCloud-synced backend registry's per-key winners (including
    /// tombstones) into the saved connections — one atomic pass under the
    /// persistence lock (see `SyncedBackendConnectionMerge` for the rules).
    /// A tombstone that removes the active connection also clears the active
    /// pointer; the outcome flags it so the caller can disconnect/route away.
    /// A failed keychain write reports a no-op outcome (pointer untouched) so
    /// the caller never disconnects while the saved list still holds the
    /// connection; the merge simply retries on the next registry read.
    @discardableResult
    func mergeSyncedBackends(records: [SyncedBackendRecord]) -> SyncedBackendMergeOutcome {
        migrateLegacyPairingIfNeeded()
        guard let connections = readConnectionsLocked() else {
            return SyncedBackendMergeOutcome(
                addedIds: [],
                updatedIds: [],
                removedIds: [],
                removedActiveConnection: false,
                registryUndecodable: true
            )
        }
        let result = SyncedBackendConnectionMerge.merge(records: records, into: connections)
        var removedActive = false
        if result.changed {
            guard saveConnectionsLocked(result.connections) else {
                return SyncedBackendMergeOutcome(
                    addedIds: [],
                    updatedIds: [],
                    removedIds: [],
                    removedActiveConnection: false
                )
            }
            if let activeId = activeConnectionIdLocked(),
                result.removedIds.contains(activeId) {
                defaults.removeObject(forKey: activeConnectionIdKey)
                removedActive = true
            }
        }
        return SyncedBackendMergeOutcome(
            addedIds: result.addedIds,
            updatedIds: result.updatedIds,
            removedIds: result.removedIds,
            removedActiveConnection: removedActive
        )
    }

    // nil distinguishes an undecodable registry from a valid empty registry.
    // swiftlint:disable:next discouraged_optional_collection
    private func readConnectionsLocked() -> [StoredConnection]? {
        guard let data = loadDataFromKeychain(account: keychainAccountConnections) else {
            return []
        }
        return try? JSONDecoder().decode([StoredConnection].self, from: data)
    }

    private func loadConnectionsLocked() -> [StoredConnection] {
        readConnectionsLocked() ?? []
    }

    @discardableResult
    private func saveConnectionsLocked(_ connections: [StoredConnection]) -> Bool {
        guard let data = try? JSONEncoder().encode(connections) else { return false }
        return saveDataToKeychain(data: data, account: keychainAccountConnections)
    }

    private func activeConnectionIdLocked() -> UUID? {
        guard let raw = defaults.string(forKey: activeConnectionIdKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// One-time migration of the legacy single pairing (Keychain `serverInfo`+`apiToken`,
    /// or the even older UserDefaults `pairedServer`) into the connections list.
    /// Legacy entries are only removed after the new blob is written successfully.
    private func migrateLegacyPairingIfNeeded() {
        guard loadDataFromKeychain(account: keychainAccountConnections) == nil else { return }

        var serverData = loadDataFromKeychain(account: keychainAccountServer)
        if serverData == nil {
            serverData = defaults.data(forKey: serverKey)
        }
        guard let data = serverData,
              let server = try? JSONDecoder().decode(PairedServer.self, from: data),
              let token = loadStringFromKeychain(account: keychainAccountToken) else {
            return
        }

        let connection = StoredConnection(server: server, token: token)
        guard saveConnectionsLocked([connection]) else { return }
        defaults.set(connection.id.uuidString, forKey: activeConnectionIdKey)

        deleteFromKeychain(account: keychainAccountServer)
        deleteFromKeychain(account: keychainAccountToken)
        defaults.removeObject(forKey: serverKey)
    }
    // MARK: - Pairing (compatibility shims over the connections API)

    @discardableResult
    func savePairing(server: PairedServer, token: String) -> Bool {
        let outcome = upsertConnectionWithOutcome(
            StoredConnection(server: server, token: token)
        )
        guard outcome.persisted else { return false }
        setActiveConnection(id: outcome.connection.id)
        return true
    }

    func loadPairing() -> (server: PairedServer, token: String)? {
        guard let connection = activeConnection() else { return nil }
        return (connection.server, connection.token)
    }

    /// Forgets the active connection (removes it from the saved list).
    @discardableResult
    func clearPairing() -> Bool {
        if let connection = activeConnection() {
            guard deleteConnection(id: connection.id) else { return false }
        }
        // Clean up any legacy entries
        deleteFromKeychain(account: keychainAccountToken)
        deleteFromKeychain(account: keychainAccountServer)
        defaults.removeObject(forKey: serverKey)
        return true
    }

    // MARK: - Keychain

    @discardableResult
    func saveDataToKeychain(data: Data, account: String) -> Bool {
        keychainStorage.save(data: data, service: keychainService, account: account)
    }

    func loadDataFromKeychain(account: String) -> Data? {
        keychainStorage.load(service: keychainService, account: account)
    }

    func loadStringFromKeychain(account: String) -> String? {
        guard let data = loadDataFromKeychain(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteFromKeychain(account: String) {
        keychainStorage.delete(service: keychainService, account: account)
    }
}
