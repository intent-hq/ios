import Combine
import SwiftUI

enum ViewMode: String, CaseIterable {
    case recent = "Recent"
    case repo = "Repo"
    case status = "Status"
}

enum WorkspaceDisplayStatus: String, CaseIterable {
    case failed
    case blocked
    case needsAttention
    case idle
    case notStarted
    case inProgress
    case unread
    case complete
    case prReady
    case prOpen
    case prMerged
    /// A wire value this build does not know (a newer daemon's status) —
    /// rendered neutrally rather than being folded into another status.
    case unknown

    /// Maps the BE-owned wire value (snake_case) to a display status.
    /// Returns nil for unknown values.
    init?(wireValue: String) {
        switch wireValue {
        case "failed": self = .failed
        case "blocked": self = .blocked
        case "needs_attention": self = .needsAttention
        case "idle": self = .idle
        case "not_started": self = .notStarted
        case "in_progress": self = .inProgress
        case "unread": self = .unread
        case "complete": self = .complete
        case "pr_ready": self = .prReady
        case "pr_open": self = .prOpen
        case "pr_merged": self = .prMerged
        default: return nil
        }
    }

    var color: Color {
        switch self {
        case .failed: return Color(red: 0.94, green: 0.27, blue: 0.27) // Red #EF4444
        case .blocked: return Color(red: 0.86, green: 0.15, blue: 0.15) // Dark red #DC2626
        case .needsAttention: return Color(red: 0.96, green: 0.62, blue: 0.043) // Amber #F59E0B
        case .idle: return Color.gray.opacity(0.6)
        case .notStarted: return Color.gray.opacity(0.4)
        case .inProgress: return Color(red: 0.0, green: 0.74, blue: 1.0) // Cyan #00BCFF
        case .unread: return Color(red: 0.23, green: 0.51, blue: 0.96) // Blue #3B82F6
        case .complete: return Color(red: 0.0, green: 0.74, blue: 0.49) // Green #00BD7D
        case .prReady: return Color(red: 0.13, green: 0.77, blue: 0.37) // Green #22C55E
        case .prOpen: return Color(red: 0.43, green: 0.50, blue: 0.96) // Indigo
        case .prMerged: return Color.purple
        case .unknown: return Color.gray.opacity(0.5)
        }
    }

    var label: String {
        switch self {
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .needsAttention: return "Needs Attention"
        case .idle: return "Idle"
        case .notStarted: return "No Code Changes"
        case .inProgress: return "In Progress"
        case .unread: return "Unread"
        case .complete: return "Complete"
        case .prReady: return "PR Mergeable"
        case .prOpen: return "PR Open"
        case .prMerged: return "PR Merged"
        case .unknown: return "Unknown"
        }
    }

    /// Order for the Status view grouping. This is presentation ordering that
    /// matches the FE sidebar status view — notably `idle` sits above
    /// `inProgress` there — not the BE-owned derivation precedence (which a
    /// workspace never needs here: it already resolves to a single status).
    /// The new values slot in at their precedence-consistent positions and
    /// unknown values sort last.
    var sortOrder: Int {
        switch self {
        case .failed: return 0
        case .blocked: return 1
        case .needsAttention: return 2
        case .idle: return 3
        case .inProgress: return 4
        case .unread: return 5
        case .prReady: return 6
        case .prOpen: return 7
        case .notStarted: return 8
        case .complete: return 9
        case .prMerged: return 10
        case .unknown: return 11
        }
    }
}

/// Resolves the display status for a workspace from the BE-owned
/// `displayStatus` wire value. The daemon always emits the field, including
/// on the lite workspace.subscribe snapshot (intent-hq/intentd#743); an
/// absent field renders as `.notStarted`, while a value this build does not
/// recognize renders as `.unknown` rather than being mislabeled.
func resolveDisplayStatus(for workspace: Workspace) -> WorkspaceDisplayStatus {
    guard let wireValue = workspace.displayStatus else { return .notStarted }
    return WorkspaceDisplayStatus(wireValue: wireValue) ?? .unknown
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

