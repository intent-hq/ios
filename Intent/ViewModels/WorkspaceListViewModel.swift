import Combine
import SwiftUI

enum ViewMode: String, CaseIterable {
    case recent = "Recent"
    case repo = "Repo"
    case status = "Status"
}

enum WorkspaceDisplayStatus: String, CaseIterable {
    case idle
    case notStarted
    case inProgress
    case complete
    case prReady
    case prOpen
    case prMerged

    /// Maps the BE-owned wire value (snake_case) to a display status.
    /// Returns nil for unknown values.
    init?(wireValue: String) {
        switch wireValue {
        case "idle": self = .idle
        case "not_started": self = .notStarted
        case "in_progress": self = .inProgress
        case "complete": self = .complete
        case "pr_ready": self = .prReady
        case "pr_open": self = .prOpen
        case "pr_merged": self = .prMerged
        default: return nil
        }
    }

    var color: Color {
        switch self {
        case .idle: return Color.gray.opacity(0.6)
        case .notStarted: return Color.gray.opacity(0.4)
        case .inProgress: return Color(red: 0.0, green: 0.74, blue: 1.0) // Cyan #00BCFF
        case .complete: return Color(red: 0.0, green: 0.74, blue: 0.49) // Green #00BD7D
        case .prReady: return Color(red: 0.13, green: 0.77, blue: 0.37) // Green #22C55E
        case .prOpen: return Color(red: 0.43, green: 0.50, blue: 0.96) // Indigo
        case .prMerged: return Color.purple
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .notStarted: return "No Code Changes"
        case .inProgress: return "In Progress"
        case .complete: return "Complete"
        case .prReady: return "PR Mergeable"
        case .prOpen: return "PR Open"
        case .prMerged: return "PR Merged"
        }
    }

    /// Order for the Status view grouping (matches the FE sidebar status view)
    var sortOrder: Int {
        switch self {
        case .idle: return 0
        case .inProgress: return 1
        case .prReady: return 2
        case .prOpen: return 3
        case .notStarted: return 4
        case .complete: return 5
        case .prMerged: return 6
        }
    }
}

/// Resolves the display status for a workspace from the BE-owned
/// `displayStatus` wire value. The daemon always emits the field, including
/// on the lite workspace.subscribe snapshot (intent-hq/intentd#743); a
/// missing or unrecognized value renders as `.notStarted`.
func resolveDisplayStatus(for workspace: Workspace) -> WorkspaceDisplayStatus {
    workspace.displayStatus.flatMap { WorkspaceDisplayStatus(wireValue: $0) } ?? .notStarted
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
        let dict = Dictionary(grouping: filteredWorkspaces) { resolveDisplayStatus(for: $0) }
        return dict.sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key.label, $0.value) }
    }
}

