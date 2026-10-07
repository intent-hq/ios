import Combine
import Foundation

struct ConnectionUpsertOutcome {
    let connection: StoredConnection
    let persisted: Bool
    let registryReadError: ConnectionRegistryReadError?
    var registryUndecodable: Bool { registryReadError == .malformed }
}

class PersistenceManager {
    static let shared = DemoMode.isEnabled
        ? PersistenceManager.ephemeral()
        : PersistenceManager(backendPublisher: SyncedBackendPublisher.production(), invitedRegistry: InvitedSessionRegistry.production())

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
    /// Explicit opt-in: custom/test/ephemeral stores never publish through a
    /// production writer. Only `shared` installs it outside the test host.
    let backendPublisher: SyncedBackendPublisher?
    let invitedRegistry: InvitedSessionRegistry?
    var invitedRefreshInProgress = false

    /// Published only after a saved connection mutation succeeds. Window
    /// labels observe their own record, independently of the last-used pointer.
    var connectionsDidChange: AnyPublisher<Void, Never> { connectionsChanged.eraseToAnyPublisher() }
    private let connectionsChanged = PassthroughSubject<Void, Never>()

    init(
        defaults: UserDefaults = .standard,
        keychainStorage: KeychainStorage = SecItemKeychainStorage(),
        backendPublisher: SyncedBackendPublisher? = nil,
        invitedRegistry: InvitedSessionRegistry? = nil
    ) {
        self.defaults = defaults
        self.keychainStorage = keychainStorage
        self.backendPublisher = backendPublisher
        self.invitedRegistry = invitedRegistry
    }
}

extension PersistenceManager {
    // MARK: - Connections

    func loadConnections() -> [StoredConnection] {
        loadConnectionsWithOutcome().connections ?? []
    }

    /// Use this at storage entry/retry boundaries instead of treating a failed
    /// compatibility `loadConnections()` read as an ordinary empty list.
    func loadConnectionsWithOutcome() -> ConnectionRegistryReadResult {
        let result = readConnectionsLocked()
        guard case .missing = result else { return result }
        return migrateLegacyPairingIfNeeded()
    }

    func isConnectionRegistryUndecodable() -> Bool {
        readConnectionsLocked().error == .malformed
    }

    /// Inserts the connection, or updates the existing entry in place (preserving its
    /// id) when its certificate fingerprint matches, or one at the same port
    /// shares at least one host or tailcat tunnel address. Returns the stored value.
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
        let read = loadConnectionsWithOutcome()
        guard var connections = read.connections else {
            return ConnectionUpsertOutcome(
                connection: connection,
                persisted: false,
                registryReadError: read.error
            )
        }
        var stored: StoredConnection
        if let index = connections.firstIndex(where: { Self.matchesPairing($0, incoming: connection) }) {
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
                    tcAddress: Self.invitedTunnelAddress(connection, fallback: existing.server.tcAddress)
                ),
                token: connection.token,
                displayName: connection.displayName,
                lastConnectedAt: connection.lastConnectedAt ?? existing.lastConnectedAt,
                // Keep the last observed clock; a deliberate local pairing
                // gets its own pending edit clock before the atomic save.
                syncUpdatedAt: connection.syncUpdatedAt ?? existing.syncUpdatedAt
            )
            stored.principal = connection.principal ?? existing.principal
            stored.invitedSyncPayload = connection.invitedSyncPayload ?? existing.invitedSyncPayload
            stored.pendingSyncUpdatedAt = connection.invitedPersonKey == nil ? existing.pendingSyncUpdatedAt : connection.pendingSyncUpdatedAt
            stored.localPairingSyncClock = connection.localPairingSyncClock ?? existing.localPairingSyncClock
            preparePublication(&stored, incoming: connection)
            connections[index] = stored
        } else {
            stored = connection
            preparePublication(&stored, incoming: connection)
            connections.append(stored)
        }
        return ConnectionUpsertOutcome(
            connection: stored,
            persisted: saveConnectionsLocked(connections),
            registryReadError: nil
        )
    }

    private func preparePublication(_ stored: inout StoredConnection, incoming: StoredConnection) {
        guard stored.principal?.isOwner == true, incoming.syncUpdatedAt == nil, let backendPublisher else { return }
        stored.pendingSyncUpdatedAt = max(
            backendPublisher.pairingClock(for: stored),
            (suppressedPublicationClock(id: stored.id) ?? 0) + 1
        )
        stored.localPairingSyncClock = stored.pendingSyncUpdatedAt
        stored.pendingRoutePublication = nil
    }

    private static func matchesPairing(_ stored: StoredConnection, incoming: StoredConnection) -> Bool {
        if let key = incoming.invitedPersonKey {
            return stored.invitedPersonKey == key
        }
        if stored.invitedPersonKey != nil { return false }
        if let first = stored.principal, let second = incoming.principal,
           !ConnectionPrincipal.samePerson(first.id, second.id) { return false }
        let fingerprint = SyncedBackendConnectionMerge.normalizeFingerprint(incoming.server.certFingerprint)
        if !fingerprint.isEmpty,
           SyncedBackendConnectionMerge.normalizeFingerprint(stored.server.certFingerprint) == fingerprint { return true }
        let incomingHosts = Set(incoming.server.hosts.map(SyncedBackendConnectionMerge.normalizeHost))
        return stored.server.port == incoming.server.port
            && (!incomingHosts.isDisjoint(with: stored.server.hosts.map(SyncedBackendConnectionMerge.normalizeHost))
                || incoming.server.tcAddress != nil && stored.server.tcAddress == incoming.server.tcAddress)
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
        guard var connections = loadConnectionsWithOutcome().connections else { return false }
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
        if hosts != server.hosts { queueRoutePublication(&connections[index], previousRoute: server.tcAddress) }
        guard saveConnectionsLocked(connections) else { return false }
        publishPendingBackends()
        return true
    }

    /// Replaces the stored tailcat tunnel address of the connection with the
    /// given id, preserving the record identity. Used by the post-connect
    /// refresh when `system.status` reports a `tcAddress`. No-op when the id
    /// is unknown.
    @discardableResult
    func updateConnectionTcAddress(id: UUID, tcAddress: String) -> Bool {
        guard var connections = loadConnectionsWithOutcome().connections else { return false }
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
        if tcAddress != server.tcAddress {
            queueRoutePublication(&connections[index], previousRoute: server.tcAddress, newRoute: tcAddress)
        }
        guard saveConnectionsLocked(connections) else { return false }
        publishPendingBackends()
        return true
    }

    /// Replaces the stored display name of the connection with the given id,
    /// preserving the record identity. Used by the post-connect refresh so
    /// records saved before the daemon reported a pretty hostname heal on the
    /// next successful connect. No-op when the id is unknown.
    @discardableResult
    func updateConnectionDisplayName(id: UUID, displayName: String) -> Bool {
        guard var connections = loadConnectionsWithOutcome().connections else { return false }
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return false }
        let shared = connections[index].invitedPersonKey != nil
        if connections[index].displayName == displayName,
           !shared || Self.invitedRecord(connections[index])?.object["hostname"] as? String == displayName { return true }
        connections[index].displayName = displayName
        if shared { queueInvitedDisplayNamePublication(&connections[index], displayName: displayName) }
        guard saveConnectionsLocked(connections) else { return false }
        if shared { publishPendingInvitedSessions() }
        return true
    }

    @discardableResult
    func deleteConnection(id: UUID) -> Bool {
        guard var connections = loadConnectionsWithOutcome().connections else { return false }
        guard let existing = connections.first(where: { $0.id == id }) else { return true }
        if existing.invitedPersonKey != nil, !rememberInvitedRemoval(existing) { return false }
        connections.removeAll { $0.id == id }
        guard saveConnectionsLocked(connections) else { return false }
        if activeConnectionIdLocked() == id {
            defaults.removeObject(forKey: activeConnectionIdKey)
        }
        publishPendingInvitedSessions()
        return true
    }

    /// The last-used backend pointer (window model v2: no longer a
    /// navigation concept — it only seeds which backend a fresh window
    /// binds to at launch).
    func activeConnection() -> StoredConnection? {
        guard let connections = loadConnectionsWithOutcome().connections else { return nil }
        guard let id = activeConnectionIdLocked() else { return nil }
        return connections.first { $0.id == id }
    }

    @discardableResult
    func setActiveConnection(id: UUID) -> Bool {
        guard loadConnectionsWithOutcome().error == nil else { return false }
        defaults.set(id.uuidString, forKey: activeConnectionIdKey)
        return true
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
        guard var connections = loadConnectionsWithOutcome().connections else { return false }
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
        let read = loadConnectionsWithOutcome()
        guard let connections = read.connections else {
            return SyncedBackendMergeOutcome(
                addedIds: [],
                updatedIds: [],
                removedIds: [],
                removedActiveConnection: false,
                registryReadError: read.error
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

    private func readConnectionsLocked() -> ConnectionRegistryReadResult {
        switch readDataFromKeychain(account: keychainAccountConnections) {
        case .missing: return .missing
        case .unavailable(let status): return .failed(.unavailable(status))
        case .malformed: return .failed(.malformed)
        case .value(let data):
            guard let connections = try? JSONDecoder().decode([StoredConnection].self, from: data) else {
                return .failed(.malformed)
            }
            return .loaded(connections)
        }
    }

    @discardableResult
    func saveConnectionsLocked(_ connections: [StoredConnection]) -> Bool {
        guard let data = try? JSONEncoder().encode(connections) else { return false }
        guard saveDataToKeychain(data: data, account: keychainAccountConnections) else { return false }
        connectionsChanged.send()
        return true
    }

    private func activeConnectionIdLocked() -> UUID? {
        guard let raw = defaults.string(forKey: activeConnectionIdKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// One-time migration of the legacy single pairing (Keychain `serverInfo`+`apiToken`,
    /// or the even older UserDefaults `pairedServer`) into the connections list.
    /// Legacy entries are only removed after the new blob is written successfully.
    private func migrateLegacyPairingIfNeeded() -> ConnectionRegistryReadResult {
        // Called only after the registry was positively identified as missing.
        // Never fall back to older defaults after a failed Keychain server read.
        let serverData: Data?
        switch readDataFromKeychain(account: keychainAccountServer) {
        case .missing: serverData = defaults.data(forKey: serverKey)
        case .value(let data): serverData = data
        case .unavailable(let status): return .failed(.unavailable(status))
        case .malformed: return .failed(.malformed)
        }
        let token: String?
        switch readLegacyToken() {
        case .success(let value): token = value
        case .failure(let error): return .failed(error)
        }
        guard let serverData else { return .missing }
        guard let server = try? JSONDecoder().decode(PairedServer.self, from: serverData) else {
            return .failed(.malformed)
        }
        guard let token else { return .missing }

        let connection = StoredConnection(server: server, token: token)
        guard saveConnectionsLocked([connection]) else { return .failed(.migrationSaveFailed) }
        defaults.set(connection.id.uuidString, forKey: activeConnectionIdKey)

        deleteFromKeychain(account: keychainAccountServer)
        deleteFromKeychain(account: keychainAccountToken)
        defaults.removeObject(forKey: serverKey)
        return .loaded([connection])
    }

    private func readLegacyToken() -> Result<String?, ConnectionRegistryReadError> {
        switch readDataFromKeychain(account: keychainAccountToken) {
        case .missing: return .success(nil)
        case .unavailable(let status): return .failure(.unavailable(status))
        case .malformed: return .failure(.malformed)
        case .value(let data):
            guard let token = String(data: data, encoding: .utf8) else { return .failure(.malformed) }
            return .success(token)
        }
    }

    // MARK: - Pairing (compatibility shims over the connections API)

    @discardableResult
    func savePairing(server: PairedServer, token: String) -> Bool {
        let outcome = upsertConnectionWithOutcome(
            StoredConnection(server: server, token: token)
        )
        guard outcome.persisted else { return false }
        guard setActiveConnection(id: outcome.connection.id) else { return false }
        publishPendingBackends()
        return true
    }

    func loadPairing() -> (server: PairedServer, token: String)? {
        guard let connection = activeConnection() else { return nil }
        return (connection.server, connection.token)
    }

    /// Forgets the active connection (removes it from the saved list).
    @discardableResult
    func clearPairing() -> Bool {
        guard let connections = loadConnectionsWithOutcome().connections else { return false }
        // Do not erase legacy entries if their prerequisite reads failed, even
        // when a newer registry exists and therefore needs no migration.
        for account in [keychainAccountServer, keychainAccountToken] {
            switch readDataFromKeychain(account: account) {
            case .unavailable, .malformed: return false
            case .missing, .value: break
            }
        }
        if let connection = connections.first(where: { $0.id == activeConnectionIdLocked() }) {
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
        readDataFromKeychain(account: account).data
    }

    func readDataFromKeychain(account: String) -> KeychainReadResult {
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
