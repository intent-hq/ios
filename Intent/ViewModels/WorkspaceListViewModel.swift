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
    case complete
    case prReady
    case prOpen
    case prMerged
    /// A wire value this build does not know (a newer daemon's status) —
    /// rendered neutrally rather than being folded into another status.
    case unknown

    /// Maps the BE-owned wire value (snake_case) to a display status.
    /// Returns nil for unknown values.
    /// The retired `"unread"` value (older daemons) maps to `.idle`: unread
    /// is now the workspace `attention` flag rendered as a dot overlay, not
    /// a first-class status.
    init?(wireValue: String) {
        switch wireValue {
        case "failed": self = .failed
        case "blocked": self = .blocked
        case "needs_attention": self = .needsAttention
        case "idle": self = .idle
        case "not_started": self = .notStarted
        case "in_progress": self = .inProgress
        case "unread": self = .idle
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
        case .prReady: return 5
        case .prOpen: return 6
        case .notStarted: return 7
        case .complete: return 8
        case .prMerged: return 9
        case .unknown: return 10
        }
    }
}

/// The unread-dot blue (#3B82F6), shared by the row overlay and any other
/// unread affordances.
let workspaceUnreadColor = Color(red: 0.23, green: 0.51, blue: 0.96)

/// True when the workspace carries the server-owned unread attention flag
/// (the blue dot). `review_required` and `none` don't count — only `unread`
/// is cleared by opening the workspace (workspace.markSeen).
func hasUnreadAttention(_ workspace: Workspace) -> Bool {
    workspace.attention == "unread"
}

/// True when the row should show the grey static waiting dot (protocol 6.17
/// orthogonal `waiting` flag). Dot precedence: running > unread > waiting —
/// the waiting dot never outranks the green running or blue unread dots.
/// Informational only: waiting never feeds attention or badge escalation.
func showsWaitingDot(_ workspace: Workspace) -> Bool {
    workspace.waiting
        && workspace.activity?.lowercased() != "agent_running"
        && !hasUnreadAttention(workspace)
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

