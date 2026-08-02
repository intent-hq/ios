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

    private init() {}

    // MARK: - Connections

    func loadConnections() -> [StoredConnection] {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            return loadConnectionsLocked()
        }
    }

    /// Inserts the connection, or updates the existing entry in place (preserving its
    /// id) when one with the same host set + port already exists. Returns the stored value.
    @discardableResult
    func upsertConnection(_ connection: StoredConnection) -> StoredConnection {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            var connections = loadConnectionsLocked()
            let stored: StoredConnection
            if let index = connections.firstIndex(where: {
                Set($0.server.hosts) == Set(connection.server.hosts)
                    && $0.server.port == connection.server.port
            }) {
                let existing = connections[index]
                stored = StoredConnection(
                    id: existing.id,
                    server: connection.server,
                    token: connection.token,
                    displayName: connection.displayName,
                    lastConnectedAt: connection.lastConnectedAt ?? existing.lastConnectedAt
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

    func deleteConnection(id: UUID) {
        syncQueue.sync {
            migrateLegacyPairingIfNeeded()
            var connections = loadConnectionsLocked()
            connections.removeAll { $0.id == id }
            saveConnectionsLocked(connections)
            if activeConnectionIdLocked() == id {
                UserDefaults.standard.removeObject(forKey: activeConnectionIdKey)
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
            UserDefaults.standard.set(id.uuidString, forKey: activeConnectionIdKey)
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
        guard let raw = UserDefaults.standard.string(forKey: activeConnectionIdKey) else { return nil }
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
            serverData = UserDefaults.standard.data(forKey: serverKey)
        }
        guard let data = serverData,
              let server = try? JSONDecoder().decode(PairedServer.self, from: data),
              let token = loadStringFromKeychain(account: keychainAccountToken) else {
            return
        }

        let connection = StoredConnection(server: server, token: token)
        guard saveConnectionsLocked([connection]) else { return }
        UserDefaults.standard.set(connection.id.uuidString, forKey: activeConnectionIdKey)

        deleteFromKeychain(account: keychainAccountServer)
        deleteFromKeychain(account: keychainAccountToken)
        UserDefaults.standard.removeObject(forKey: serverKey)
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
        UserDefaults.standard.removeObject(forKey: serverKey)
    }

    // MARK: - Draft Messages

    private let draftPrefix = "draft_"

    func saveDraft(_ text: String, workspaceId: String, agentId: String) {
        let key = "\(draftPrefix)\(workspaceId)_\(agentId)"
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
    }

    func loadDraft(workspaceId: String, agentId: String) -> String {
        let key = "\(draftPrefix)\(workspaceId)_\(agentId)"
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    func clearDraft(workspaceId: String, agentId: String) {
        let key = "\(draftPrefix)\(workspaceId)_\(agentId)"
        UserDefaults.standard.removeObject(forKey: key)
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
        let defaults = UserDefaults.standard
        defaults.set(screen.screen, forKey: lastScreenKey)
        defaults.set(screen.workspaceId, forKey: lastWorkspaceIdKey)
        defaults.set(screen.agentId, forKey: lastAgentIdKey)
        defaults.set(screen.agentName, forKey: lastAgentNameKey)
        defaults.set(screen.noteId, forKey: lastNoteIdKey)
        defaults.set(screen.noteTitle, forKey: lastNoteTitleKey)
    }

    func loadLastScreen() -> SavedScreen? {
        let defaults = UserDefaults.standard
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
        let defaults = UserDefaults.standard
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
            UserDefaults.standard.set(dict, forKey: workspaceScreensKey)
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
            UserDefaults.standard.set(dict, forKey: workspaceScreensKey)
        }
    }

    private func loadWorkspaceScreensDict() -> [String: Data] {
        dispatchPrecondition(condition: .onQueue(syncQueue))
        return (UserDefaults.standard.dictionary(forKey: workspaceScreensKey) as? [String: Data]) ?? [:]
    }

    // MARK: - Per-Workspace Tab

    private let workspaceTabsKey = "workspaceTabs"

    func saveWorkspaceTab(workspaceId: String, tab: Int) {
        syncQueue.sync {
            var dict = loadWorkspaceTabsDict()
            dict[workspaceId] = tab
            UserDefaults.standard.set(dict, forKey: workspaceTabsKey)
        }
    }

    func loadWorkspaceTab(workspaceId: String) -> Int? {
        syncQueue.sync {
            loadWorkspaceTabsDict()[workspaceId]
        }
    }

    private func loadWorkspaceTabsDict() -> [String: Int] {
        dispatchPrecondition(condition: .onQueue(syncQueue))
        return (UserDefaults.standard.dictionary(forKey: workspaceTabsKey) as? [String: Int]) ?? [:]
    }

    // MARK: - Keychain

    @discardableResult
    func saveDataToKeychain(data: Data, account: String) -> Bool {
        deleteFromKeychain(account: account) // Remove existing

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func loadDataFromKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func loadStringFromKeychain(account: String) -> String? {
        guard let data = loadDataFromKeychain(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

