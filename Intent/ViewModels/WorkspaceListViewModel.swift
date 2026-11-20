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
    case unknown

    static let allCases: [Self] = [
        .failed, .blocked, .needsAttention, .idle, .notStarted, .inProgress,
        .complete, .prReady, .prOpen, .prQueued, .prMerged, .unknown
    ]

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

func hasUnreadAttention(_ workspace: Workspace) -> Bool {
    workspace.attention == "unread"
}

func hasRunningAgents(_ workspace: Workspace) -> Bool {
    workspace.activity?.lowercased() == "agent_running"
}

func showsWaitingDot(_ workspace: Workspace) -> Bool {
    workspace.waiting
        && !hasRunningAgents(workspace)
        && !hasUnreadAttention(workspace)
}

func resolveDisplayStatus(for workspace: Workspace) -> WorkspaceDisplayStatus {
    guard let wireValue = workspace.displayStatus else { return .notStarted }
    return WorkspaceDisplayStatus(wireValue: wireValue) ?? .unknown
}

@MainActor
@Observable class WorkspaceListViewModel {
    var viewMode: ViewMode {
        didSet { persistence.saveWorkspaceListViewMode(viewMode) }
    }
    var searchText = ""
    private(set) var collapsedGroups: [ViewMode: Set<String>]

    var showArchived: Bool {
        get { workspaceStore.showArchived }
        set { workspaceStore.showArchived = newValue }
    }

    @ObservationIgnored private let workspaceStore: WorkspaceStore
    @ObservationIgnored private let persistence: PersistenceManager
    @ObservationIgnored private let activityTime: @MainActor (Workspace) -> TimeInterval
    @ObservationIgnored private var activityTimes: [String: ActivityTime] = [:]
    @ObservationIgnored private var sortedCache: SortedWorkspaces?
    @ObservationIgnored private var derivedCache: DerivedWorkspaces?

    init(
        workspaceStore: WorkspaceStore,
        persistence: PersistenceManager = .shared,
        activityTime: @escaping @MainActor (Workspace) -> TimeInterval = workspaceActivityDisplayTime
    ) {
        self.workspaceStore = workspaceStore
        self.persistence = persistence
        self.viewMode = persistence.loadWorkspaceListViewMode()
        self.collapsedGroups = [
            .repo: persistence.loadCollapsedGroups(for: .repo),
            .status: persistence.loadCollapsedGroups(for: .status)
        ]
        self.activityTime = activityTime
    }

    var workspaces: [Workspace] {
        workspaceStore.workspaces
    }

    var isLoading: Bool {
        workspaceStore.isLoading
    }

    var loadFailureMessage: String? {
        guard workspaces.isEmpty else { return nil }
        return workspaceStore.loadPhase.failureMessage
    }

    func retryLoad() async {
        await workspaceStore.fetchAll()
    }

    var hasSearchQuery: Bool {
        !normalizedSearchText.isEmpty
    }

    var filteredWorkspaces: [Workspace] {
        derivedWorkspaces.filtered
    }

    var groupedByRepo: [(String, [Workspace])] {
        derivedWorkspaces.byRepo
    }

    var presentation: WorkspaceListPresentation {
        WorkspaceListPresentation(viewMode: viewMode, collapsedGroups: collapsedGroups, searchText: searchText)
    }

    func isGroupExpanded(_ key: String, in mode: ViewMode) -> Bool {
        presentation.isGroupExpanded(key, in: mode)
    }

    func toggleGroup(_ key: String, in mode: ViewMode) {
        guard !hasSearchQuery else { return }
        var keys = collapsedGroups[mode, default: []]
        if keys.remove(key) == nil { keys.insert(key) }
        collapsedGroups[mode] = keys
        persistence.saveCollapsedGroups(keys, for: mode)
    }

    var groupedByStatus: [(String, [Workspace])] {
        derivedWorkspaces.byStatus
    }

    private var derivedWorkspaces: DerivedWorkspaces {
        let revision = workspaceStore.workspacesRevision
        let query = normalizedSearchText
        let includeArchived = showArchived
        if let derivedCache, derivedCache.revision == revision, derivedCache.query == query,
           derivedCache.includeArchived == includeArchived {
            return derivedCache
        }
        let sorted = sortedWorkspaces(revision: revision, includeArchived: includeArchived)
        let filtered = WorkspaceListRows.filter(sorted, query: query)
        let result = DerivedWorkspaces(
            revision: revision,
            query: query,
            includeArchived: includeArchived,
            filtered: filtered,
            byRepo: WorkspaceListRows.byRepo(filtered),
            byStatus: WorkspaceListRows.byStatus(filtered)
        )
        derivedCache = result
        return result
    }

    private func sortedWorkspaces(revision: UInt64, includeArchived: Bool) -> [Workspace] {
        if let sortedCache, sortedCache.revision == revision,
           sortedCache.includeArchived == includeArchived { return sortedCache.workspaces }
        var nextTimes: [String: ActivityTime] = [:]
        let timed = workspaces.compactMap { workspace -> (workspace: Workspace, time: TimeInterval)? in
            guard WorkspaceListRows.isListed(workspace, includeArchived: includeArchived) else { return nil }
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
        activityTimes = nextTimes
        let sorted = timed.sorted { $0.time > $1.time }.map(\.workspace)
        sortedCache = SortedWorkspaces(revision: revision, includeArchived: includeArchived, workspaces: sorted)
        return sorted
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
        let includeArchived: Bool
        let workspaces: [Workspace]
    }

    private struct DerivedWorkspaces {
        let revision: UInt64
        let query: String
        let includeArchived: Bool
        let filtered: [Workspace]
        let byRepo: [(String, [Workspace])]
        let byStatus: [(String, [Workspace])]
    }

    private var normalizedSearchText: String {
        presentation.normalizedSearchText
    }
}
