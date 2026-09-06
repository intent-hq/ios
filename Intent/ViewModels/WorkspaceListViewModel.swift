import Observation
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
        case .failed: return Constants.Colors.WorkspaceStatus.failed
        case .blocked: return Constants.Colors.WorkspaceStatus.blocked
        case .needsAttention: return Constants.Colors.WorkspaceStatus.needsAttention
        case .idle: return Constants.Colors.WorkspaceStatus.idle
        case .notStarted: return Constants.Colors.WorkspaceStatus.notStarted
        case .inProgress: return Constants.Colors.WorkspaceStatus.inProgress
        case .complete: return Constants.Colors.WorkspaceStatus.complete
        case .prReady: return Constants.Colors.WorkspaceStatus.prReady
        case .prOpen: return Constants.Colors.WorkspaceStatus.prOpen
        case .prMerged: return Constants.Colors.WorkspaceStatus.prMerged
        case .unknown: return Constants.Colors.WorkspaceStatus.unknown
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
    /// matches the FE sidebar status view — attention states first, then a
    /// lifecycle progression (idle → not started → in progress → complete →
    /// PR open → mergeable → merged) — not the BE-owned derivation precedence
    /// (which a workspace never needs here: it already resolves to a single
    /// status). Unknown values sort last.
    var sortOrder: Int {
        switch self {
        case .failed: return 0
        case .blocked: return 1
        case .needsAttention: return 2
        case .idle: return 3
        case .notStarted: return 4
        case .inProgress: return 5
        case .complete: return 6
        case .prOpen: return 7
        case .prReady: return 8
        case .prMerged: return 9
        case .unknown: return 10
        }
    }
}

/// The unread-dot blue (#3B82F6), shared by the row overlay and any other
/// unread affordances.
let workspaceUnreadColor = Constants.Colors.WorkspaceStatus.unread

/// True when the workspace carries the server-owned unread attention flag
/// (the blue dot). `review_required` and `none` don't count — only `unread`
/// is cleared by opening the workspace (workspace.markSeen).
func hasUnreadAttention(_ workspace: Workspace) -> Bool {
    workspace.attention == "unread"
}

/// True when the workspace's daemon-reported activity is "agent_running"
/// (the green dot). Shared by the row's green-dot overlay and the waiting-dot
/// precedence check so the two predicates can never drift apart.
func hasRunningAgents(_ workspace: Workspace) -> Bool {
    workspace.activity?.lowercased() == "agent_running"
}

/// True when the row should show the grey static waiting dot (protocol 6.17
/// orthogonal `waiting` flag). Dot precedence: running > unread > waiting —
/// the waiting dot never outranks the green running or blue unread dots.
/// Informational only: waiting never feeds attention or badge escalation.
func showsWaitingDot(_ workspace: Workspace) -> Bool {
    workspace.waiting
        && !hasRunningAgents(workspace)
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
@Observable class WorkspaceListViewModel {
    var viewMode: ViewMode = .recent
    var searchText = ""

    var workspaces: [Workspace] {
        WorkspaceStore.shared.workspaces
    }

    var isLoading: Bool {
        WorkspaceStore.shared.isLoading
    }

    var hasSearchQuery: Bool {
        !normalizedSearchText.isEmpty
    }

    var filteredWorkspaces: [Workspace] {
        let query = normalizedSearchText
        let active = workspaces.filter { ws in
            let s = ws.status?.lowercased() ?? ""
            return s != "archived" && s != "deleted"
        }
        let filtered = query.isEmpty ? active : active.filter { ws in
            ws.title.localizedCaseInsensitiveContains(query) ||
            (ws.branch?.localizedCaseInsensitiveContains(query) ?? false) ||
            (ws.repositoryName?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return filtered.sorted(by: isWorkspaceActivityMoreRecent)
    }

    /// Groups keyed by repo, ordered by the activity time of each group's most
    /// recent member (its first, since `filteredWorkspaces` is already sorted)
    /// — the same rule as the FE sidebar's `groupedByRepo`.
    var groupedByRepo: [(String, [Workspace])] {
        var keys: [String] = []
        var groups: [String: [Workspace]] = [:]
        for ws in filteredWorkspaces {
            let key: String
            if let owner = ws.repositoryOwner, let name = ws.repositoryName {
                key = "\(owner)/\(name)"
            } else {
                key = ws.repositoryName ?? "Unknown"
            }
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(ws)
        }
        return keys
            .map { ($0, groups[$0] ?? []) }
            .sorted { lhs, rhs in
                guard let l = lhs.1.first, let r = rhs.1.first else { return false }
                return isWorkspaceActivityMoreRecent(l, than: r)
            }
    }

    var groupedByStatus: [(String, [Workspace])] {
        let dict = Dictionary(grouping: filteredWorkspaces) { resolveDisplayStatus(for: $0) }
        return dict.sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key.label, $0.value) }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

