import Observation
import SwiftUI

enum ViewMode: String, CaseIterable {
    case recent = "Recent"
    case repo = "Repo"
    case status = "Status"
}

enum WorkspaceDisplayStatus: String, CaseIterable {
    private static let wireStatuses: [String: Self] = [
        "failed": .failed,
        "blocked": .blocked,
        "needs_attention": .needsAttention,
        "idle": .idle,
        "not_started": .notStarted,
        "in_progress": .inProgress,
        "unread": .idle,
        "complete": .complete,
        "pr_ready": .prReady,
        "pr_open": .prOpen,
        "pr_queued": .prQueued,
        "pr_merged": .prMerged
    ]

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
        guard let status = Self.wireStatuses[wireValue] else { return nil }
        self = status
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
        // Queued and merged share Blue 600 in the Figma Status Colors legend.
        case .prQueued: return Constants.Colors.WorkspaceStatus.prMerged
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
    @ObservationIgnored private let activityTime: @MainActor (Workspace) -> TimeInterval
    @ObservationIgnored private var activityTimes: [String: ActivityTime] = [:]
    @ObservationIgnored private var sortedCache: SortedWorkspaces?
    @ObservationIgnored private var derivedCache: DerivedWorkspaces?

    init(
        workspaceStore: WorkspaceStore,
        activityTime: @escaping @MainActor (Workspace) -> TimeInterval = workspaceActivityDisplayTime
    ) {
        self.workspaceStore = workspaceStore
        self.activityTime = activityTime
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
        derivedWorkspaces.filtered
    }

    /// Groups keyed by repo, ordered by the activity time of each group's most
    /// recent member (its first, since `filteredWorkspaces` is already sorted)
    /// — the same rule as the FE sidebar's `groupedByRepo`.
    var groupedByRepo: [(String, [Workspace])] {
        derivedWorkspaces.byRepo
    }

    var groupedByStatus: [(String, [Workspace])] {
        derivedWorkspaces.byStatus
    }

    private var derivedWorkspaces: DerivedWorkspaces {
        // Read both observable inputs even on a hit so SwiftUI remains subscribed.
        // Cache storage itself must not publish changes during a view read.
        let revision = workspaceStore.workspacesRevision
        let query = normalizedSearchText
        if let derivedCache, derivedCache.revision == revision, derivedCache.query == query {
            return derivedCache
        }
        let sorted = sortedWorkspaces(revision: revision)
        let filtered = query.isEmpty ? sorted : sorted.filter { workspace in
            workspace.title.localizedCaseInsensitiveContains(query) ||
            (workspace.branch?.localizedCaseInsensitiveContains(query) ?? false) ||
            (workspace.repositoryName?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let statuses = Dictionary(grouping: filtered) { resolveDisplayStatus(for: $0) }
        let result = DerivedWorkspaces(
            revision: revision,
            query: query,
            filtered: filtered,
            byRepo: repoGroups(filtered),
            byStatus: statuses.sorted { $0.key.sortOrder < $1.key.sortOrder }
                .map { ($0.key.label, $0.value) }
        )
        derivedCache = result
        return result
    }

    private func sortedWorkspaces(revision: UInt64) -> [Workspace] {
        if let sortedCache, sortedCache.revision == revision { return sortedCache.workspaces }
        var nextTimes: [String: ActivityTime] = [:]
        let timed = workspaces.compactMap { workspace -> (workspace: Workspace, time: TimeInterval)? in
            let status = workspace.status?.lowercased() ?? ""
            guard status != "archived", status != "deleted" else { return nil }
            let inputs = ActivityTimeInputs(workspace)
            let entry: ActivityTime
            if let cached = activityTimes[workspace.id], cached.inputs == inputs {
                entry = cached
            } else {
                entry = ActivityTime(inputs: inputs, time: activityTime(workspace))
            }
            nextTimes[workspace.id] = entry
            return (workspace, entry.time)
        }
        // Prune removed workspaces; metadata-only updates retain parsed keys.
        activityTimes = nextTimes
        let sorted = timed.sorted { $0.time > $1.time }.map(\.workspace)
        sortedCache = SortedWorkspaces(revision: revision, workspaces: sorted)
        return sorted
    }

    private func repoGroups(_ workspaces: [Workspace]) -> [(String, [Workspace])] {
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
        // First-seen order already follows each group's most recent member,
        // including stable ties; no second sort or timestamp parse is needed.
        return keys.map { ($0, groups[$0] ?? []) }
    }

    private struct ActivityTimeInputs: Equatable {
        let lastActivity: String?
        let createdAt: String?
        let updatedAt: String?

        init(_ workspace: Workspace) {
            lastActivity = workspace.lastActivity
            createdAt = workspace.createdAt
            updatedAt = workspace.updatedAt
        }
    }

    private struct ActivityTime {
        let inputs: ActivityTimeInputs
        let time: TimeInterval
    }

    private struct SortedWorkspaces {
        let revision: UInt64
        let workspaces: [Workspace]
    }

    private struct DerivedWorkspaces {
        let revision: UInt64
        let query: String
        let filtered: [Workspace]
        let byRepo: [(String, [Workspace])]
        let byStatus: [(String, [Workspace])]
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
