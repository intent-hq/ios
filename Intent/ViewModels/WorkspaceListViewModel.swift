import Observation
import SwiftUI

enum ViewMode: String, CaseIterable {
    case recent = "Recent"
    case repo = "Repo"
    case status = "Status"
}

enum WorkspaceDisplayStatus: String, CaseIterable {
    private enum SortOrder {
        static let failed = 0
        static let blocked = 1
        static let needsAttention = 2
        static let idle = 3
        static let notStarted = 4
        static let inProgress = 5
        static let complete = 6
        static let prOpen = 7
        static let prReady = 8
        static let prQueued = 9
        static let prMerged = 10
        static let unknown = 11
    }

    case blocked
    case complete
    case failed
    case idle
    case inProgress
    case needsAttention
    case notStarted
    case prMerged
    case prOpen
    case prQueued
    case prReady
    /// A wire value this build does not know (a newer daemon's status) —
    /// rendered neutrally rather than being folded into another status.
    case unknown

    /// Stable historical iteration order, independent of declaration order.
    static let allCases: [Self] = [
        .failed, .blocked, .needsAttention, .idle, .notStarted, .inProgress,
        .complete, .prReady, .prOpen, .prQueued, .prMerged, .unknown
    ]

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
        case "pr_queued": self = .prQueued
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
        // Shares the open colour, matching the FE's `text-info` for both.
        case .prQueued: return Constants.Colors.WorkspaceStatus.prOpen
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
        case .prQueued: return "PR Queued"
        case .prMerged: return "PR Merged"
        case .unknown: return "Unknown"
        }
    }

    /// Order for the Status view grouping. This is presentation ordering that
    /// matches the FE sidebar status view — attention states first, then a
    /// lifecycle progression (idle → not started → in progress → complete →
    /// PR open → mergeable → queued → merged) — not the BE-owned derivation precedence
    /// (which a workspace never needs here: it already resolves to a single
    /// status). Unknown values sort last.
    var sortOrder: Int {
        switch self {
        case .failed: return SortOrder.failed
        case .blocked: return SortOrder.blocked
        case .needsAttention: return SortOrder.needsAttention
        case .idle: return SortOrder.idle
        case .notStarted: return SortOrder.notStarted
        case .inProgress: return SortOrder.inProgress
        case .complete: return SortOrder.complete
        case .prOpen: return SortOrder.prOpen
        case .prReady: return SortOrder.prReady
        case .prQueued: return SortOrder.prQueued
        case .prMerged: return SortOrder.prMerged
        case .unknown: return SortOrder.unknown
        }
    }
}

/// The unread-dot blue (#3B82F6), shared by the row overlay and any other
/// unread affordances.
let kWorkspaceUnreadColor = Constants.Colors.WorkspaceStatus.unread

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

    /// The window's workspace store, injected from its `BackendSession`.
    @ObservationIgnored private let workspaceStore: WorkspaceStore

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
    }

    var workspaces: [Workspace] {
        workspaceStore.workspaces
    }

    var isLoading: Bool {
        workspaceStore.isLoading
    }

    var hasSearchQuery: Bool {
        !normalizedSearchText.isEmpty
    }

    var filteredWorkspaces: [Workspace] {
        let query = normalizedSearchText
        let active = workspaces.filter { workspace in
            let status = workspace.status?.lowercased() ?? ""
            return status != "archived" && status != "deleted"
        }
        let filtered = query.isEmpty ? active : active.filter { workspace in
            workspace.title.localizedCaseInsensitiveContains(query) ||
            (workspace.branch?.localizedCaseInsensitiveContains(query) ?? false) ||
            (workspace.repositoryName?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return filtered.sorted(by: isWorkspaceActivityMoreRecent)
    }

    /// Groups keyed by repo, ordered by the activity time of each group's most
    /// recent member (its first, since `filteredWorkspaces` is already sorted)
    /// — the same rule as the FE sidebar's `groupedByRepo`.
    var groupedByRepo: [(String, [Workspace])] {
        var keys: [String] = []
        var groups: [String: [Workspace]] = [:]
        for workspace in filteredWorkspaces {
            let key: String
            if let owner = workspace.repositoryOwner, let name = workspace.repositoryName {
                key = "\(owner)/\(name)"
            } else {
                key = workspace.repositoryName ?? "Unknown"
            }
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(workspace)
        }
        return keys
            .map { ($0, groups[$0] ?? []) }
            .sorted { lhs, rhs in
                guard let leftWorkspace = lhs.1.first,
                      let rightWorkspace = rhs.1.first else { return false }
                return isWorkspaceActivityMoreRecent(leftWorkspace, than: rightWorkspace)
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
