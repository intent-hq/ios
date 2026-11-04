import Foundation

extension PersistenceManager {
    // MARK: - Last Viewed Screen (keyed per backend)

    private static let lastScreensKey = "lastScreens"
    // Legacy single-slot keys (pre window model v2): read once as a
    // migration fallback for the connection that was active when they were
    // written, then cleaned up.
    private static let lastScreenKey = "lastScreen"
    private static let lastWorkspaceIdKey = "lastWorkspaceId"
    private static let lastAgentIdKey = "lastAgentId"
    private static let lastAgentNameKey = "lastAgentName"
    private static let lastNoteTitleKey = "lastNoteTitle"
    private static let lastNoteIdKey = "lastNoteId"

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
        defaults.set(dict, forKey: Self.lastScreensKey)
    }

    func loadLastScreen(for connectionID: UUID) -> SavedScreen? {
        let dict = loadLastScreensDict()
        if let data = dict[connectionID.uuidString] as? Data {
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
        defaults.set(dict, forKey: Self.lastScreensKey)
        if activeConnection()?.id == connectionID {
            clearLegacyLastScreen()
        }
    }

    private func loadLastScreensDict() -> [String: Any] {
        defaults.dictionary(forKey: Self.lastScreensKey) ?? [:]
    }

    private func loadLegacyLastScreen() -> SavedScreen? {
        guard let screen = defaults.string(forKey: Self.lastScreenKey) else { return nil }
        return SavedScreen(
            screen: screen,
            workspaceId: defaults.string(forKey: Self.lastWorkspaceIdKey),
            agentId: defaults.string(forKey: Self.lastAgentIdKey),
            agentName: defaults.string(forKey: Self.lastAgentNameKey),
            noteId: defaults.string(forKey: Self.lastNoteIdKey),
            noteTitle: defaults.string(forKey: Self.lastNoteTitleKey)
        )
    }

    private func clearLegacyLastScreen() {
        defaults.removeObject(forKey: Self.lastScreenKey)
        defaults.removeObject(forKey: Self.lastWorkspaceIdKey)
        defaults.removeObject(forKey: Self.lastAgentIdKey)
        defaults.removeObject(forKey: Self.lastAgentNameKey)
        defaults.removeObject(forKey: Self.lastNoteIdKey)
        defaults.removeObject(forKey: Self.lastNoteTitleKey)
    }

    private static let workspaceListViewModeKey = "workspaceListViewMode"

    func saveWorkspaceListViewMode(_ mode: ViewMode) {
        defaults.set(mode.rawValue, forKey: Self.workspaceListViewModeKey)
    }

    func loadWorkspaceListViewMode() -> ViewMode {
        defaults.string(forKey: Self.workspaceListViewModeKey).flatMap(ViewMode.init(rawValue:)) ?? .recent
    }

    /// `workspaceListCollapsedRepoGroups` or `workspaceListCollapsedStatusGroups`.
    private static func collapsedGroupsKey(for mode: ViewMode) -> String {
        "workspaceListCollapsed\(mode.rawValue)Groups"
    }

    func saveCollapsedGroups(_ keys: Set<String>, for mode: ViewMode) {
        if keys.isEmpty {
            defaults.removeObject(forKey: Self.collapsedGroupsKey(for: mode))
        } else {
            defaults.set(keys.sorted(), forKey: Self.collapsedGroupsKey(for: mode))
        }
    }

    func loadCollapsedGroups(for mode: ViewMode) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.collapsedGroupsKey(for: mode)) ?? [])
    }

    // MARK: - Per-Workspace Tab

    private static let workspaceTabsKey = "workspaceTabs"

    func saveWorkspaceTab(workspaceId: String, tab: Int) {
        var dict = loadWorkspaceTabsDict()
        dict[workspaceId] = tab
        defaults.set(dict, forKey: Self.workspaceTabsKey)
    }

    func loadWorkspaceTab(workspaceId: String) -> Int? {
        loadWorkspaceTabsDict()[workspaceId]
    }

    private func loadWorkspaceTabsDict() -> [String: Int] {
        (defaults.dictionary(forKey: Self.workspaceTabsKey) as? [String: Int]) ?? [:]
    }
}
