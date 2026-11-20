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

    let defaults: UserDefaults

    var keychainStorage: KeychainStorage
    let backendPublisher: SyncedBackendPublisher?
    let invitedRegistry: InvitedSessionRegistry?
    var invitedRefreshInProgress = false // swiftlint:disable:this state_phase_flag

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
    func loadConnections() -> [StoredConnection] {
        loadConnectionsWithOutcome().connections ?? []
    }

    func loadConnectionsWithOutcome() -> ConnectionRegistryReadResult {
        let result = readConnectionsLocked()
        guard case .missing = result else { return result }
        return migrateLegacyPairingIfNeeded()
    }

    func isConnectionRegistryUndecodable() -> Bool {
        readConnectionsLocked().error == .malformed
    }

    @discardableResult
    func upsertConnection(_ connection: StoredConnection) -> StoredConnection {
        upsertConnectionWithOutcome(connection).connection
    }

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
                    tcAddress: Self.invitedTunnelAddress(connection, fallback: existing.server.tcAddress)
                ),
                token: connection.token,
                displayName: connection.displayName,
                lastConnectedAt: connection.lastConnectedAt ?? existing.lastConnectedAt,
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
        preserveLegacyDraftOwner()
        if existing.invitedPersonKey != nil, !rememberInvitedRemoval(existing) { return false }
        connections.removeAll { $0.id == id }
        guard saveConnectionsLocked(connections) else { return false }
        if activeConnectionIdLocked() == id {
            defaults.removeObject(forKey: activeConnectionIdKey)
        }
        publishPendingInvitedSessions()
        return true
    }

    func activeConnection() -> StoredConnection? {
        guard let connections = loadConnectionsWithOutcome().connections else { return nil }
        guard let id = activeConnectionIdLocked() else { return nil }
        return connections.first { $0.id == id }
    }

    @discardableResult
    func setActiveConnection(id: UUID) -> Bool {
        guard loadConnectionsWithOutcome().error == nil else { return false }
        preserveLegacyDraftOwner()
        defaults.set(id.uuidString, forKey: activeConnectionIdKey)
        return true
    }

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
            preserveLegacyDraftOwner()
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

    private func migrateLegacyPairingIfNeeded() -> ConnectionRegistryReadResult {
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

    @discardableResult
    func clearPairing() -> Bool {
        guard let connections = loadConnectionsWithOutcome().connections else { return false }
        for account in [keychainAccountServer, keychainAccountToken] {
            switch readDataFromKeychain(account: account) {
            case .unavailable, .malformed: return false
            case .missing, .value: break
            }
        }
        if let connection = connections.first(where: { $0.id == activeConnectionIdLocked() }) {
            guard deleteConnection(id: connection.id) else { return false }
        }
        deleteFromKeychain(account: keychainAccountToken)
        deleteFromKeychain(account: keychainAccountServer)
        defaults.removeObject(forKey: serverKey)
        return true
    }

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
