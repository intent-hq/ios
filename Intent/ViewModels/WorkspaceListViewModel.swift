import Combine
import SwiftUI

enum ViewMode: String, CaseIterable {
    case recent = "Recent"
    case repo = "Repo"
    case status = "Status"
}

enum WorkspaceDisplayStatus: String, CaseIterable {
    case notStarted
    case inProgress
    case complete
    case prOpen
    case prMerged

    var color: Color {
        switch self {
        case .notStarted: return Color.gray.opacity(0.4)
        case .inProgress: return Color(red: 0.0, green: 0.74, blue: 1.0) // Cyan #00BCFF
        case .complete: return Color(red: 0.0, green: 0.74, blue: 0.49) // Green #00BD7D
        case .prOpen: return Color(red: 0.43, green: 0.50, blue: 0.96) // Indigo
        case .prMerged: return Color.purple
        }
    }

    var label: String {
        switch self {
        case .notStarted: return "No Code Changes"
        case .inProgress: return "In Progress"
        case .complete: return "Complete"
        case .prOpen: return "PR Open"
        case .prMerged: return "PR Merged"
        }
    }

    /// Order for the Status view grouping
    var sortOrder: Int {
        switch self {
        case .inProgress: return 0
        case .prOpen: return 1
        case .notStarted: return 2
        case .complete: return 3
        case .prMerged: return 4
        }
    }
}

func deriveDisplayStatus(from workspace: Workspace) -> WorkspaceDisplayStatus {
    // PR merged
    if workspace.prStatus == "Merged" {
        return .prMerged
    }
    // PR open/draft
    if workspace.prStatus == "Open" || workspace.prStatus == "Draft" {
        return .prOpen
    }
    let totalTasks = workspace.taskStatsTotal ?? 0
    let completedTasks = workspace.taskStatsCompleted ?? 0
    let inProgressTasks = workspace.taskStatsInProgress ?? 0
    // All tasks complete
    if totalTasks > 0 && completedTasks == totalTasks {
        return .complete
    }
    // Tasks in progress or some completed, or has code changes
    let hasFiles = (workspace.diffSummaryTotalFiles ?? 0) > 0
    if inProgressTasks > 0 || (totalTasks > 0 && completedTasks > 0) || hasFiles {
        return .inProgress
    }
    // Default
    return .notStarted
}

@MainActor
class WorkspaceListViewModel: ObservableObject {
    @Published var viewMode: ViewMode = .recent
    @Published var searchText = ""

    private var cancellable: AnyCancellable?

    init() {
        // Forward WorkspaceStore changes to trigger view updates
        cancellable = WorkspaceStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var workspaces: [Workspace] { WorkspaceStore.shared.workspaces }
    var isLoading: Bool { WorkspaceStore.shared.isLoading }

    var filteredWorkspaces: [Workspace] {
        let active = workspaces.filter { ws in
            let s = ws.status?.lowercased() ?? ""
            return s != "archived" && s != "deleted"
        }
        let filtered = searchText.isEmpty ? active : active.filter { ws in
            ws.title.localizedCaseInsensitiveContains(searchText) ||
            (ws.branch?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            (ws.repositoryName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
        return filtered.sorted {
            let t0 = $0.lastActivity ?? $0.updatedAt ?? ""
            let t1 = $1.lastActivity ?? $1.updatedAt ?? ""
            return t0 > t1
        }
    }

    var groupedByRepo: [(String, [Workspace])] {
        let dict = Dictionary(grouping: filteredWorkspaces) { ws in
            if let owner = ws.repositoryOwner, let name = ws.repositoryName {
                return "\(owner)/\(name)"
            }
            return ws.repositoryName ?? "Unknown"
        }
        return dict.sorted { $0.key < $1.key }
    }

    var groupedByStatus: [(String, [Workspace])] {
        let dict = Dictionary(grouping: filteredWorkspaces) { deriveDisplayStatus(from: $0) }
        return dict.sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key.label, $0.value) }
    }
}

