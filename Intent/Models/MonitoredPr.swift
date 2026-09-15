import Foundation

nonisolated enum MergeabilityState: Equatable {
    case computing
    case mergeable
    case notMergeable

    init(reported value: Bool) {
        self = value ? .mergeable : .notMergeable
    }
}

/// Last-refresh merge-requirements checklist summary (§5.42
/// `lastSnapshot`). Only the display subset is modeled; `mergeable`,
/// `mergeBlockedReason`, and `approvals.needed` are presence-detected.
struct MonitoredPrSnapshot: Equatable {
    struct Checks: Equatable {
        let total: Int
        let passed: Int
        let failed: Int
        let pending: Int
    }
    struct Approvals: Equatable {
        let decision: String
        let have: Int
        /// Required approvals; absent when branch rules are unreadable.
        let needed: Int?
        let changesRequested: Int
    }
    struct Threads: Equatable {
        let unresolved: Int
    }

    let state: String
    let isDraft: Bool
    let hasConflicts: Bool
    let isBehind: Bool
    /// Forge tri-state; `.computing` while the forge has not reported it.
    let mergeability: MergeabilityState
    let mergeBlockedReason: String?
    let checks: Checks
    let approvals: Approvals
    let threads: Threads

    nonisolated static func parse(_ dict: [String: Any]) -> Self? {
        guard let state = dict["state"] as? String,
              let isDraft = dict["isDraft"] as? Bool,
              let hasConflicts = dict["hasConflicts"] as? Bool,
              let isBehind = dict["isBehind"] as? Bool,
              let checksDict = dict["checks"] as? [String: Any],
              let approvalsDict = dict["approvals"] as? [String: Any],
              let threadsDict = dict["threads"] as? [String: Any],
              let decision = approvalsDict["decision"] as? String
        else { return nil }
        return Self(
            state: state,
            isDraft: isDraft,
            hasConflicts: hasConflicts,
            isBehind: isBehind,
            mergeability: (dict["mergeable"] as? Bool).map(MergeabilityState.init(reported:)) ?? .computing,
            mergeBlockedReason: dict["mergeBlockedReason"] as? String,
            checks: Checks(
                total: checksDict["total"] as? Int ?? 0,
                passed: checksDict["passed"] as? Int ?? 0,
                failed: checksDict["failed"] as? Int ?? 0,
                pending: checksDict["pending"] as? Int ?? 0
            ),
            approvals: Approvals(
                decision: decision,
                have: approvalsDict["have"] as? Int ?? 0,
                needed: approvalsDict["needed"] as? Int,
                changesRequested: approvalsDict["changesRequested"] as? Int ?? 0
            ),
            threads: Threads(
                unresolved: threadsDict["unresolved"] as? Int ?? 0
            )
        )
    }
}

/// Wire `PrMonitor` shape (PROTOCOL §5.42, v6.1). `title`/`url`/`lastSnapshot`
/// are present once the monitor has a successful poll baseline. Optional
/// fields are presence-detected (nil when absent), never defaulted in.
struct MonitoredPr: Identifiable, Equatable {
    /// Monitor lifecycle state (PROTOCOL §5.42). `active` is the live state;
    /// `completed` (PR merged/closed — rows retained so merged PRs stay
    /// visible) and `cancelled` (rows excluded from lists) are terminal.
    enum State: String {
        case active
        case completed
        case cancelled
    }

    /// Last-refresh merge-requirements checklist summary.
    typealias Snapshot = MonitoredPrSnapshot

    let monitorId: String
    let workspaceId: String
    let agentId: String
    /// Combined `"owner/name"` string.
    let repo: String
    let prNumber: Int
    var state: State
    /// Human-readable change lines accumulated since the last emit
    /// (awaiting the debounce window; `[]` when nothing is pending).
    var pendingChanges: [String]
    var hasPendingChanges: Bool
    let createdAt: String?
    let updatedAt: String?
    var pendingSince: String?
    let lastChangeAt: String?
    let lastPolledAt: String?
    /// Most recent forge-poll error; cleared by a successful poll.
    let lastError: String?
    let title: String?
    let url: String?
    let lastSnapshot: Snapshot?

    var id: String { monitorId }

    /// Whether the monitor is still watching its PR.
    var isActive: Bool {
        state == .active
    }

    static func parseMonitor(_ dict: [String: Any]) -> Self? {
        guard let monitorId = dict["monitorId"] as? String,
              let repo = dict["repo"] as? String,
              let prNumber = dict["prNumber"] as? Int,
              let stateRaw = dict["state"] as? String,
              let state = State(rawValue: stateRaw) else { return nil }
        return Self(
            monitorId: monitorId,
            workspaceId: dict["workspaceId"] as? String ?? "",
            agentId: dict["agentId"] as? String ?? "",
            repo: repo,
            prNumber: prNumber,
            state: state,
            pendingChanges: dict["pendingChanges"] as? [String] ?? [],
            hasPendingChanges: dict["hasPendingChanges"] as? Bool ?? false,
            createdAt: dict["createdAt"] as? String,
            updatedAt: dict["updatedAt"] as? String,
            pendingSince: dict["pendingSince"] as? String,
            lastChangeAt: dict["lastChangeAt"] as? String,
            lastPolledAt: dict["lastPolledAt"] as? String,
            lastError: dict["lastError"] as? String,
            title: dict["title"] as? String,
            url: dict["url"] as? String,
            lastSnapshot: (dict["lastSnapshot"] as? [String: Any]).flatMap(Snapshot.parse)
        )
    }
}
