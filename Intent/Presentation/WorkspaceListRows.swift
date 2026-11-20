import Foundation

struct WorkspaceListPresentation: Equatable {
    var viewMode: ViewMode
    var collapsedGroups: [ViewMode: Set<String>]
    var searchText: String

    init(viewMode: ViewMode = .recent, collapsedGroups: [ViewMode: Set<String>] = [:], searchText: String = "") {
        self.viewMode = viewMode
        self.collapsedGroups = collapsedGroups
        self.searchText = searchText
    }

    @MainActor
    init(persistence: PersistenceManager) {
        self.init(
            viewMode: persistence.loadWorkspaceListViewMode(),
            collapsedGroups: [
                .repo: persistence.loadCollapsedGroups(for: .repo),
                .status: persistence.loadCollapsedGroups(for: .status)
            ]
        )
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isGroupExpanded(_ key: String, in mode: ViewMode) -> Bool {
        !normalizedSearchText.isEmpty || collapsedGroups[mode]?.contains(key) != true
    }
}

@MainActor
enum WorkspaceListRows {
    static func sorted(
        _ workspaces: [Workspace],
        includeArchived: Bool,
        activityTime: @MainActor (Workspace) -> TimeInterval
    ) -> [Workspace] {
        workspaces
            .filter { isListed($0, includeArchived: includeArchived) }
            .map { (workspace: $0, time: activityTime($0)) }
            .sorted { $0.time > $1.time }
            .map(\.workspace)
    }

    static func isListed(_ workspace: Workspace, includeArchived: Bool) -> Bool {
        let status = workspace.status?.lowercased() ?? ""
        return status != "deleted" && (includeArchived || status != "archived")
    }

    static func filter(_ workspaces: [Workspace], query: String) -> [Workspace] {
        guard !query.isEmpty else { return workspaces }
        return workspaces.filter { workspace in
            workspace.title.localizedCaseInsensitiveContains(query) ||
            (workspace.branch?.localizedCaseInsensitiveContains(query) ?? false) ||
            (workspace.repositoryName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    static func byRepo(_ workspaces: [Workspace]) -> [(String, [Workspace])] {
        var keys: [String] = []
        var groups: [String: [Workspace]] = [:]
        for workspace in workspaces {
            let key: String
            if let owner = workspace.repositoryOwner, let name = workspace.repositoryName {
                key = "\(owner)/\(name)"
            } else {
                key = workspace.repositoryName ?? "Unknown"
            }
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(workspace)
        }
        return keys.map { ($0, groups[$0] ?? []) }
    }

    static func byStatus(_ workspaces: [Workspace]) -> [(String, [Workspace])] {
        Dictionary(grouping: workspaces) { resolveDisplayStatus(for: $0) }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key.label, $0.value) }
    }

    static func visible(
        filtered: [Workspace],
        presentation: WorkspaceListPresentation
    ) -> [Workspace] {
        let mode = presentation.viewMode
        let groups: [(String, [Workspace])]
        switch mode {
        case .recent: return filtered
        case .repo: groups = byRepo(filtered)
        case .status: groups = byStatus(filtered)
        }
        return groups.flatMap { key, rows in
            presentation.isGroupExpanded(key, in: mode) ? rows : []
        }
    }

    static func visible(
        _ workspaces: [Workspace],
        includeArchived: Bool,
        presentation: WorkspaceListPresentation,
        activityTime: @MainActor (Workspace) -> TimeInterval = workspaceActivityDisplayTime
    ) -> [Workspace] {
        let sorted = sorted(workspaces, includeArchived: includeArchived, activityTime: activityTime)
        return visible(filtered: filter(sorted, query: presentation.normalizedSearchText), presentation: presentation)
    }
}
