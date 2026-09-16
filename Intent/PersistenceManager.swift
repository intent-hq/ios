import Foundation
import Security

class PersistenceManager {
    /// Under `--demo-data` the shared manager runs over an ephemeral store so
    /// a simulator's real pairing state can never bind the window or restore
    /// a saved screen out from under the fixture flow (UI tests reuse
    /// simulators that `scripts/xcodebuild.sh test-ios` does not erase).
    static let shared = DemoMode.isEnabled ? PersistenceManager.ephemeral() : PersistenceManager()

    /// A manager over a demo defaults suite wiped on creation plus an
    /// in-memory keychain: starts unpaired and leaves no state behind.
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

    init(defaults: UserDefaults = .standard,
         keychainStorage: KeychainStorage = SecItemKeychainStorage()) {
        self.defaults = defaults
        self.keychainStorage = keychainStorage
    }

    // MARK: - Connections

    func loadConnections() -> [StoredConnection] {
        migrateLegacyPairingIfNeeded()
        return loadConnectionsLocked()
    }

    /// True when a saved-connections blob exists but cannot be decoded (corrupt
    /// or written by a newer schema). Reads then behave as if the list were
    /// empty, but every write path refuses to save from that empty base so the
    /// original blob — and the tokens in it — survive until an explicit
    /// recovery path is chosen.
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
    /// `registryUndecodable` is true when nothing was written because the
    /// existing blob could not be decoded (see `isConnectionRegistryUndecodable`).
    @discardableResult
    func upsertConnectionWithOutcome(
        _ connection: StoredConnection
    ) -> (connection: StoredConnection, persisted: Bool, registryUndecodable: Bool) {
        migrateLegacyPairingIfNeeded()
        guard var connections = readConnectionsLocked() else {
            return (connection, false, true)
        }
        let stored: StoredConnection
        if let index = connections.firstIndex(where: {
            $0.server.port == connection.server.port
                && (!Set($0.server.hosts).isDisjoint(with: connection.server.hosts)
                    || (connection.server.tcAddress != nil
                        && $0.server.tcAddress == connection.server.tcAddress))
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
        return (stored, saveConnectionsLocked(connections), false)
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
        return loadConnections().max {
            ($0.lastConnectedAt ?? .distantPast) < ($1.lastConnectedAt ?? .distantPast)
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
    /// An undecodable existing blob also reports a no-op outcome (flagged
    /// `registryUndecodable`) — merging into an empty base would overwrite it.
    @discardableResult
    func mergeSyncedBackends(records: [SyncedBackendRecord]) -> SyncedBackendMergeOutcome {
        migrateLegacyPairingIfNeeded()
        guard let connections = readConnectionsLocked() else {
            return SyncedBackendMergeOutcome(
                addedIds: [], updatedIds: [], removedIds: [],
                removedActiveConnection: false, registryUndecodable: true)
        }
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

    /// Reads the saved list: an absent blob is an empty list; a blob that fails
    /// to decode is nil. Write paths must go through this (not
    /// `loadConnectionsLocked`) so they never save over an undecodable blob.
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
            StoredConnection(server: server, token: token))
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

    // MARK: - Last Viewed Screen (keyed per backend)

    private let lastScreensKey = "lastScreens"
    // Legacy single-slot keys (pre window model v2): read once as a
    // migration fallback for the connection that was active when they were
    // written, then cleaned up.
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

    func saveLastScreen(_ screen: SavedScreen, for connectionID: UUID) {
        var dict = loadLastScreensDict()
        if let data = try? JSONEncoder().encode(screen) {
            dict[connectionID.uuidString] = data
        }
        defaults.set(dict, forKey: lastScreensKey)
    }

    func loadLastScreen(for connectionID: UUID) -> SavedScreen? {
        let dict = loadLastScreensDict()
        if let data = dict[connectionID.uuidString] {
            return try? JSONDecoder().decode(SavedScreen.self, from: data)
        }
        // Legacy migration: the old single-slot screen belonged to the
        // connection that was active when it was saved.
        guard let legacy = loadLegacyLastScreen(),
              activeConnection()?.id == connectionID else { return nil }
        saveLastScreen(legacy, for: connectionID)
        clearLegacyLastScreen()
        return legacy
    }

    func clearLastScreen(for connectionID: UUID) {
        var dict = loadLastScreensDict()
        dict.removeValue(forKey: connectionID.uuidString)
        defaults.set(dict, forKey: lastScreensKey)
        if activeConnection()?.id == connectionID {
            clearLegacyLastScreen()
        }
    }

    private func loadLastScreensDict() -> [String: Data] {
        (defaults.dictionary(forKey: lastScreensKey) as? [String: Data]) ?? [:]
    }

    private func loadLegacyLastScreen() -> SavedScreen? {
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

    private func clearLegacyLastScreen() {
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
        defaults.set(dict, forKey: workspaceScreensKey)
    }

    func loadWorkspaceScreen(workspaceId: String) -> SavedScreen? {
        let dict = loadWorkspaceScreensDict()
        guard let data = dict[workspaceId] else { return nil }
        return try? JSONDecoder().decode(SavedScreen.self, from: data)
    }

    func clearWorkspaceScreen(workspaceId: String) {
        var dict = loadWorkspaceScreensDict()
        dict.removeValue(forKey: workspaceId)
        defaults.set(dict, forKey: workspaceScreensKey)
    }

    private func loadWorkspaceScreensDict() -> [String: Data] {
        return (defaults.dictionary(forKey: workspaceScreensKey) as? [String: Data]) ?? [:]
    }

    // MARK: - Per-Workspace Tab

    private let workspaceTabsKey = "workspaceTabs"

    func saveWorkspaceTab(workspaceId: String, tab: Int) {
        var dict = loadWorkspaceTabsDict()
        dict[workspaceId] = tab
        defaults.set(dict, forKey: workspaceTabsKey)
    }

    func loadWorkspaceTab(workspaceId: String) -> Int? {
        loadWorkspaceTabsDict()[workspaceId]
    }

    private func loadWorkspaceTabsDict() -> [String: Int] {
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

/// Process-local backend for `--demo-data`: never touches the real Keychain,
/// so demo launches start unpaired regardless of the simulator's saved
/// connections.
final class EphemeralKeychainStorage: KeychainStorage, @unchecked Sendable {
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

/// Production backend over the Security framework.
///
/// ## Credential backup / accessibility policy (intent-hq/ios#263)
///
/// Two credential classes live in the Keychain with deliberately different
/// policies; `KeychainAccessibilityPolicyTests` pins both.
///
/// - **Local credentials** — everything this store writes under service
///   `com.intent.companion`: the `connections` blob (each paired daemon's
///   bearer token + certificate pin) and the legacy `apiToken` /
///   `serverInfo` items. Added with `kSecAttrAccessibleAfterFirstUnlock`,
///   NOT synchronizable and in no shared access group. They never leave the
///   device via iCloud Keychain, but they DO ride encrypted backups and
///   device-to-device migration, so a phone restored or migrated onto new
///   hardware keeps its pairings. `AfterFirstUnlock` (rather than
///   `WhenUnlocked`) keeps the token reachable for background work while the
///   device is locked.
///
///   A `...ThisDeviceOnly` class is deliberately NOT used — a usability
///   trade-off, not a security equivalence. It would make these items
///   unusable after a restore or migration onto a DIFFERENT device (Apple
///   protects such items with the device UID in backups; a same-device
///   restore keeps them), forcing a fresh pairing per daemon. For daemons
///   that also appear in the desktop-written synced registry the pairing
///   comes back on its own, but pairings made only on this phone, or with
///   desktop sync disabled/unavailable, have no synced counterpart — for
///   those, `ThisDeviceOnly` WOULD remove the cross-device backup-restore
///   exposure, at the cost of re-pairing. The current policy accepts that
///   exposure for compatibility with existing items and restore usability.
///   Changing it is a product/security decision (see ios#263) and needs a
///   migration: `save` updates existing items in place, so a new
///   accessibility class only applies to items added after the change.
/// - **Synced backend records** — `SyncedBackendRegistry` (service
///   `com.cloudlands.intent.backends`, shared access group) are written by the
///   desktop app with `kSecAttrSynchronizable = true` and are read-only on
///   iOS; their accessibility is the writer's policy.
struct SecItemKeychainStorage: KeychainStorage {
    struct SecurityCalls {
        let update: ([String: Any], [String: Any]) -> OSStatus
        let add: ([String: Any]) -> OSStatus
        let delete: ([String: Any]) -> OSStatus

        static let live = SecurityCalls(
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { query in SecItemAdd(query as CFDictionary, nil) },
            delete: { query in SecItemDelete(query as CFDictionary) }
        )
    }

    private let security: SecurityCalls

    init(security: SecurityCalls = .live) {
        self.security = security
    }

    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = security.update(query, [kSecValueData as String: data])
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery.merge([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { _, new in new }
        return security.add(addQuery) == errSecSuccess
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
        _ = security.delete(query)
    }
}

