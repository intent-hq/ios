import Foundation
import Security

class PersistenceManager {
    static let shared = PersistenceManager()

    private let serverKey = "pairedServer"
    private let keychainService = "com.intent.companion"
    private let keychainAccountToken = "apiToken"
    private let keychainAccountServer = "serverInfo"

    private init() {}

    // MARK: - Pairing

    func savePairing(server: PairedServer, token: String) {
        // Save server to Keychain
        if let data = try? JSONEncoder().encode(server) {
            saveDataToKeychain(data: data, account: keychainAccountServer)
        }
        // Save token to Keychain
        saveDataToKeychain(data: Data(token.utf8), account: keychainAccountToken)
    }

    func loadPairing() -> (server: PairedServer, token: String)? {
        var serverData = loadDataFromKeychain(account: keychainAccountServer)

        // Migration: check UserDefaults for existing installs
        if serverData == nil, let legacyData = UserDefaults.standard.data(forKey: serverKey) {
            // Migrate to Keychain
            saveDataToKeychain(data: legacyData, account: keychainAccountServer)
            UserDefaults.standard.removeObject(forKey: serverKey)
            serverData = legacyData
        }

        guard let data = serverData,
              let server = try? JSONDecoder().decode(PairedServer.self, from: data),
              let token = loadStringFromKeychain(account: keychainAccountToken) else {
            return nil
        }
        return (server, token)
    }

    func clearPairing() {
        deleteFromKeychain(account: keychainAccountToken)
        deleteFromKeychain(account: keychainAccountServer)
        // Clean up any legacy UserDefaults data
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
        var dict = loadWorkspaceScreensDict()
        if let data = try? JSONEncoder().encode(screen) {
            dict[workspaceId] = data
        }
        UserDefaults.standard.set(dict, forKey: workspaceScreensKey)
    }

    func loadWorkspaceScreen(workspaceId: String) -> SavedScreen? {
        let dict = loadWorkspaceScreensDict()
        guard let data = dict[workspaceId] else { return nil }
        return try? JSONDecoder().decode(SavedScreen.self, from: data)
    }

    func clearWorkspaceScreen(workspaceId: String) {
        var dict = loadWorkspaceScreensDict()
        dict.removeValue(forKey: workspaceId)
        UserDefaults.standard.set(dict, forKey: workspaceScreensKey)
    }

    private func loadWorkspaceScreensDict() -> [String: Data] {
        (UserDefaults.standard.dictionary(forKey: workspaceScreensKey) as? [String: Data]) ?? [:]
    }

    // MARK: - Per-Workspace Tab

    private let workspaceTabsKey = "workspaceTabs"

    func saveWorkspaceTab(workspaceId: String, tab: Int) {
        var dict = loadWorkspaceTabsDict()
        dict[workspaceId] = tab
        UserDefaults.standard.set(dict, forKey: workspaceTabsKey)
    }

    func loadWorkspaceTab(workspaceId: String) -> Int? {
        loadWorkspaceTabsDict()[workspaceId]
    }

    private func loadWorkspaceTabsDict() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: workspaceTabsKey) as? [String: Int]) ?? [:]
    }

    // MARK: - Keychain

    private func saveDataToKeychain(data: Data, account: String) {
        deleteFromKeychain(account: account) // Remove existing

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadDataFromKeychain(account: String) -> Data? {
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

    private func loadStringFromKeychain(account: String) -> String? {
        guard let data = loadDataFromKeychain(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

