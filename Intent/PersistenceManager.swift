import Foundation
import Security

class PersistenceManager {
    static let shared = PersistenceManager()

    let serverKey = "pairedServer"
    private let keychainService = "com.intent.companion"
    let keychainAccountToken = "apiToken"
    let keychainAccountServer = "serverInfo"
    let keychainAccountConnections = "connections"
    let activeConnectionIdKey = "activeConnectionId"
    private let syncQueue = DispatchQueue(label: "com.intent.companion.persistence", qos: .userInitiated)

    /// Backing store for non-secret values. Tests inject a private suite so
    /// persisted state (navigation, drafts, active connection id) can't leak
    /// between tests or into the real app container.
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         keychainStorage: KeychainStorage = SecItemKeychainStorage()) {
        self.defaults = defaults
        self.keychainStorage = keychainStorage
    }

    // MARK: - Connections

    func loadConnections() -> [StoredConnection] {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            return loadConnectionsLocked()
        }
    }

    /// Inserts the connection, or updates the existing entry in place (preserving its
    /// id) when one at the same port shares at least one host. Returns the stored value.
    ///
    /// Overlap (not set equality) is the match key because the post-connect route
    /// refresh grows stored host sets over time: a re-pair of the same daemon via a
    /// single manually entered host (or a QR payload with a different host list) must
    /// still update the grown record in place instead of inserting a duplicate. On a
    /// match, the existing record's hosts are kept (in order) and new hosts appended,
    /// so previously known routes are never dropped by a narrower re-pair.
    @discardableResult
    func upsertConnection(_ connection: StoredConnection) -> StoredConnection {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            var connections = loadConnectionsLocked()
            let stored: StoredConnection
            if let index = connections.firstIndex(where: {
                $0.server.port == connection.server.port
                    && !Set($0.server.hosts).isDisjoint(with: connection.server.hosts)
            }) {
                let existing = connections[index]
                let server = connection.server
                stored = StoredConnection(
                    id: existing.id,
                    server: PairedServer(
                        hosts: Self.mergeHostLists(
                            existing: existing.server.hosts, incoming: server.hosts),
                        port: server.port,
                        name: server.name,
                        pairedAt: server.pairedAt,
                        certFingerprint: server.certFingerprint
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
            saveConnectionsLocked(connections)
            return stored
        }
    }

    /// Existing hosts keep their order and are never dropped; incoming hosts not
    /// already present are appended, deduped.
    static func mergeHostLists(existing: [String], incoming: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing)
        for host in incoming where !seen.contains(host) {
            merged.append(host)
            seen.insert(host)
        }
        return merged
    }

    /// Replaces the stored host list of the connection with the given id,
    /// preserving the record identity. Unlike `upsertConnection` (which matches
    /// by host set + port and would treat a grown host set as a new pairing),
    /// this never inserts or duplicates records. No-op when the id is unknown.
    func updateConnectionHosts(id: UUID, hosts: [String]) {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            var connections = loadConnectionsLocked()
            guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
            let server = connections[index].server
            connections[index].server = PairedServer(
                hosts: hosts,
                port: server.port,
                name: server.name,
                pairedAt: server.pairedAt,
                certFingerprint: server.certFingerprint
            )
            saveConnectionsLocked(connections)
        }
    }

    /// Replaces the stored display name of the connection with the given id,
    /// preserving the record identity. Used by the post-connect refresh so
    /// records saved before the daemon reported a pretty hostname heal on the
    /// next successful connect. No-op when the id is unknown.
    func updateConnectionDisplayName(id: UUID, displayName: String) {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            var connections = loadConnectionsLocked()
            guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
            connections[index].displayName = displayName
            saveConnectionsLocked(connections)
        }
    }

    func deleteConnection(id: UUID) {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            var connections = loadConnectionsLocked()
            connections.removeAll { $0.id == id }
            saveConnectionsLocked(connections)
            if activeConnectionIdLocked() == id {
                defaults.removeObject(forKey: activeConnectionIdKey)
            }
        }
    }

    func activeConnection() -> StoredConnection? {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            guard let id = activeConnectionIdLocked() else { return nil }
            return loadConnectionsLocked().first { $0.id == id }
        }
    }

    func setActiveConnection(id: UUID) {
        syncQueue.sync {
            defaults.set(id.uuidString, forKey: activeConnectionIdKey)
        }
    }

    func touchLastConnected(id: UUID) {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            var connections = loadConnectionsLocked()
            guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
            connections[index].lastConnectedAt = Date()
            saveConnectionsLocked(connections)
        }
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
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            let connections = loadConnectionsLocked()
            let result = SyncedBackendConnectionMerge.merge(records: records, into: connections)
            var removedActive = false
            if result.changed {
                guard saveConnectionsLocked(result.connections) else {
                    return SyncedBackendMergeOutcome(
                        addedIds: [], updatedIds: [], removedIds: [],
                        removedActiveConnection: false)
                }
                if let activeId = activeConnectionIdLocked(),
                    result.removedIds.contains(activeId)
                {
                    defaults.removeObject(forKey: activeConnectionIdKey)
                    removedActive = true
                }
            }
            return SyncedBackendMergeOutcome(
                addedIds: result.addedIds,
                updatedIds: result.updatedIds,
                removedIds: result.removedIds,
                removedActiveConnection: removedActive)
        }
    }

    private func loadConnectionsLocked() -> [StoredConnection] {
        dispatchPrecondition(condition: .onQueue(syncQueue))
        guard let data = loadDataFromKeychain(account: keychainAccountConnections),
              let connections = try? JSONDecoder().decode([StoredConnection].self, from: data) else {
            return []
        }
        return connections
    }

    @discardableResult
    private func saveConnectionsLocked(_ connections: [StoredConnection]) -> Bool {
        dispatchPrecondition(condition: .onQueue(syncQueue))
        guard let data = try? JSONEncoder().encode(connections) else { return false }
        return saveDataToKeychain(data: data, account: keychainAccountConnections)
    }

    private func activeConnectionIdLocked() -> UUID? {
        dispatchPrecondition(condition: .onQueue(syncQueue))
        guard let raw = defaults.string(forKey: activeConnectionIdKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// One-time migration of the legacy single pairing (Keychain `serverInfo`+`apiToken`,
    /// or the even older UserDefaults `pairedServer`) into the connections list.
    /// Legacy entries are only removed after the new blob is written successfully.
    private func migrateLegacyPairingIfNeeded() {
        dispatchPrecondition(condition: .onQueue(syncQueue))
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

    func savePairing(server: PairedServer, token: String) {
        let stored = upsertConnection(StoredConnection(server: server, token: token))
        setActiveConnection(id: stored.id)
    }

    func loadPairing() -> (server: PairedServer, token: String)? {
        guard let connection = activeConnection() else { return nil }
        return (connection.server, connection.token)
    }

    /// Forgets the active connection (removes it from the saved list).
    func clearPairing() {
        if let connection = activeConnection() {
            deleteConnection(id: connection.id)
        }
        // Clean up any legacy entries
        deleteFromKeychain(account: keychainAccountToken)
        deleteFromKeychain(account: keychainAccountServer)
        defaults.removeObject(forKey: serverKey)
    }

    // MARK: - Draft Messages

    private let draftPrefix = "draft_"

    func saveDraft(_ text: String, workspaceId: String, agentId: String) {
        let key = "\(draftPrefix)\(workspaceId)_\(agentId)"
        if text.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }

    func loadDraft(workspaceId: String, agentId: String) -> String {
        let key = "\(draftPrefix)\(workspaceId)_\(agentId)"
        return defaults.string(forKey: key) ?? ""
    }

    func clearDraft(workspaceId: String, agentId: String) {
        let key = "\(draftPrefix)\(workspaceId)_\(agentId)"
        defaults.removeObject(forKey: key)
    }

    // MARK: - Last Viewed Screen

    private let lastScreenKey = "lastScreen"
    private let lastWorkspaceIdKey = "lastWorkspaceId"
    private let lastAgentIdKey = "lastAgentId"
    private let lastAgentNameKey = "lastAgentName"
    private let lastNoteTitleKey = "lastNoteTitle"
    private let lastNoteIdKey = "lastNoteId"

    struct SavedScreen: Codable {
        let screen: String  // "workspaceList", "workspaceDetail", "conversation", "note"
        let workspaceId: String?
        let agentId: String?
        let agentName: String?
        let noteId: String?
        let noteTitle: String?
    }

    func saveLastScreen(_ screen: SavedScreen) {
        defaults.set(screen.screen, forKey: lastScreenKey)
        defaults.set(screen.workspaceId, forKey: lastWorkspaceIdKey)
        defaults.set(screen.agentId, forKey: lastAgentIdKey)
        defaults.set(screen.agentName, forKey: lastAgentNameKey)
        defaults.set(screen.noteId, forKey: lastNoteIdKey)
        defaults.set(screen.noteTitle, forKey: lastNoteTitleKey)
    }

    func loadLastScreen() -> SavedScreen? {
        guard let screen = defaults.string(forKey: lastScreenKey) else { return nil }
        return SavedScreen(
            screen: screen,
            workspaceId: defaults.string(forKey: lastWorkspaceIdKey),
            agentId: defaults.string(forKey: lastAgentIdKey),
            agentName: defaults.string(forKey: lastAgentNameKey),
            noteId: defaults.string(forKey: lastNoteIdKey),
            noteTitle: defaults.string(forKey: lastNoteTitleKey)
        )
    }

    func clearLastScreen() {
        defaults.removeObject(forKey: lastScreenKey)
        defaults.removeObject(forKey: lastWorkspaceIdKey)
        defaults.removeObject(forKey: lastAgentIdKey)
        defaults.removeObject(forKey: lastAgentNameKey)
        defaults.removeObject(forKey: lastNoteIdKey)
        defaults.removeObject(forKey: lastNoteTitleKey)
    }

    // MARK: - Per-Workspace Screen

    private let workspaceScreensKey = "workspaceScreens"

    func saveWorkspaceScreen(workspaceId: String, screen: SavedScreen) {
        syncQueue.sync {
            var dict = loadWorkspaceScreensDict()
            if let data = try? JSONEncoder().encode(screen) {
                dict[workspaceId] = data
            }
            defaults.set(dict, forKey: workspaceScreensKey)
        }
    }

    func loadWorkspaceScreen(workspaceId: String) -> SavedScreen? {
        syncQueue.sync {
            let dict = loadWorkspaceScreensDict()
            guard let data = dict[workspaceId] else { return nil }
            return try? JSONDecoder().decode(SavedScreen.self, from: data)
        }
    }

    func clearWorkspaceScreen(workspaceId: String) {
        syncQueue.sync {
            var dict = loadWorkspaceScreensDict()
            dict.removeValue(forKey: workspaceId)
            defaults.set(dict, forKey: workspaceScreensKey)
        }
    }

    private func loadWorkspaceScreensDict() -> [String: Data] {
        dispatchPrecondition(condition: .onQueue(syncQueue))
        return (defaults.dictionary(forKey: workspaceScreensKey) as? [String: Data]) ?? [:]
    }

    // MARK: - Per-Workspace Tab

    private let workspaceTabsKey = "workspaceTabs"

    func saveWorkspaceTab(workspaceId: String, tab: Int) {
        syncQueue.sync {
            var dict = loadWorkspaceTabsDict()
            dict[workspaceId] = tab
            defaults.set(dict, forKey: workspaceTabsKey)
        }
    }

    func loadWorkspaceTab(workspaceId: String) -> Int? {
        syncQueue.sync {
            loadWorkspaceTabsDict()[workspaceId]
        }
    }

    private func loadWorkspaceTabsDict() -> [String: Int] {
        dispatchPrecondition(condition: .onQueue(syncQueue))
        return (defaults.dictionary(forKey: workspaceTabsKey) as? [String: Int]) ?? [:]
    }

    // MARK: - Keychain

    /// Backend for Keychain-stored values. Tests substitute an in-memory
    /// implementation (SecItem calls fail in headless CI simulators).
    var keychainStorage: KeychainStorage

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

/// Abstraction over Keychain item storage so tests can run hermetically.
protocol KeychainStorage {
    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool
    func load(service: String, account: String) -> Data?
    func delete(service: String, account: String)
}

/// Production backend over the Security framework.
struct SecItemKeychainStorage: KeychainStorage {
    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool {
        delete(service: service, account: account) // Remove existing

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

