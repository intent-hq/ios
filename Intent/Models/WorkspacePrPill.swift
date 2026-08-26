import Foundation

/// Pure-logic port of the Cloudlands workspace-card PR pill helpers
/// (`sidebar-changes-utils.ts`: `toPRDisplayStatus`, `monitorDisplayStatus`,
/// `mergeMonitoredPRs`, `selectPrimaryPr`, `countOtherMonitors`) so iOS picks
/// the identical primary PR and "+N" count. No networking or view concerns.
nonisolated enum WorkspacePrPill {

    /// FE `PRDisplayStatus` — the four pill buckets.
    enum Status: String, Equatable {
        case open
        case merged
        case closed
        case draft
    }

    /// Pill-relevant subset of an FE `PRInfo` row.
    struct PillPr: Equatable {
        let number: Int
        let status: Status
        let createdAt: String?
        let updatedAt: String?
        /// Monitor repo `owner/name` when the row came from a monitor on a
        /// repo other than the workspace repo; nil for same-repo rows.
        let crossRepo: String?
        /// True when the row exists only because of a monitor (no matching
        /// workspace PR row).
        let monitorOnly: Bool

        init(number: Int, status: Status, createdAt: String? = nil,
             updatedAt: String? = nil, crossRepo: String? = nil,
             monitorOnly: Bool = false) {
            self.number = number
            self.status = status
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.crossRepo = crossRepo
            self.monitorOnly = monitorOnly
        }

        /// Project a workspace detected-PR row (§7.6) into a pill row —
        /// the `mapWorkspacePRs` field subset the pill logic reads.
        init(_ pr: WorkspacePullRequest) {
            self.init(number: pr.number, status: Status(wire: pr.status),
                      createdAt: pr.createdAt, updatedAt: pr.updatedAt)
        }
    }

    /// FE `monitorDisplayStatus` (PROTOCOL §6.9): active monitors read the
    /// live snapshot state; completed ones without a snapshot verdict ended
    /// merged or closed, so default to the non-celebratory `closed`.
    static func monitorDisplayStatus(_ monitor: MonitoredPr) -> Status {
        let snapshotState = monitor.lastSnapshot?.state.lowercased()
        if snapshotState == "merged" { return .merged }
        if snapshotState == "closed" { return .closed }
        if monitor.lastSnapshot?.isDraft == true { return .draft }
        return monitor.state == .completed ? .closed : .open
    }

    /// FE `mergeMonitoredPRs`: a monitor duplicating an existing row's
    /// repo-qualified identity (`crossRepo ?? workspaceRepo` + number) only
    /// annotates it — a pill no-op, so the row is left untouched; same-repo
    /// lookups only match bare (non-`crossRepo`) rows. Unmatched monitors
    /// append as monitor-only rows with monitor timestamps standing in for
    /// the PR's own and `crossRepo` set when the repo differs.
    static func mergeMonitoredPRs(_ basePRs: [PillPr], _ monitors: [MonitoredPr],
                                  workspaceRepo: String?) -> [PillPr] {
        if monitors.isEmpty { return basePRs }
        var merged = basePRs
        for monitor in monitors {
            let sameRepo = workspaceRepo == nil || workspaceRepo?.isEmpty == true
                || monitor.repo == workspaceRepo
            let duplicatesExisting = merged.contains { pr in
                sameRepo
                    ? pr.crossRepo == nil && pr.number == monitor.prNumber
                    : pr.crossRepo == monitor.repo && pr.number == monitor.prNumber
            }
            if duplicatesExisting { continue }
            merged.append(PillPr(
                number: monitor.prNumber,
                status: monitorDisplayStatus(monitor),
                createdAt: monitor.createdAt,
                updatedAt: monitor.updatedAt,
                crossRepo: sameRepo ? nil : monitor.repo,
                monitorOnly: true
            ))
        }
        return merged
    }

    /// FE `selectPrimaryPr`: the oldest unmerged (open/draft) PR (`createdAt`
    /// asc, number asc tiebreak); otherwise the latest merged PR (`updatedAt`
    /// desc, number desc); otherwise the first remaining (closed) row.
    /// Missing timestamps sort last within their bucket. Nil on an empty
    /// pool (callers fall back to legacy `prStatus`/`prNumber`).
    static func selectPrimaryPr(_ prs: [PillPr]) -> PillPr? {
        let unmerged = prs.filter { $0.status == .open || $0.status == .draft }
        if !unmerged.isEmpty {
            return unmerged.min { a, b in
                let byCreated = compareMissingLast(a.createdAt, b.createdAt) { $0 < $1 }
                if byCreated != 0 { return byCreated < 0 }
                return a.number < b.number
            }
        }
        let merged = prs.filter { $0.status == .merged }
        if !merged.isEmpty {
            return merged.min { a, b in
                let byUpdated = compareMissingLast(a.updatedAt, b.updatedAt) { $0 > $1 }
                if byUpdated != 0 { return byUpdated < 0 }
                return a.number > b.number
            }
        }
        return prs.first
    }

    /// FE `countOtherMonitors`: the "+N" indicator — monitors whose
    /// repo-qualified number differs from the primary's. A monitor is
    /// excluded only when it matches the primary PR by number in the
    /// primary PR's repo — `primaryCrossRepo` when the primary is a
    /// cross-repo monitored row, else the workspace repo (an unknown repo
    /// matches by number alone).
    static func countOtherMonitors(_ monitors: [MonitoredPr],
                                   primaryPrNumber: Int?,
                                   repositoryOwner: String?,
                                   repositoryName: String?,
                                   primaryCrossRepo: String? = nil) -> Int {
        var workspaceRepo: String?
        if let owner = repositoryOwner, let name = repositoryName,
           !owner.isEmpty, !name.isEmpty {
            workspaceRepo = "\(owner)/\(name)"
        }
        let primaryRepo = primaryCrossRepo ?? workspaceRepo
        return monitors.filter { monitor in
            !(primaryPrNumber != nil
                && monitor.prNumber == primaryPrNumber
                && (primaryRepo == nil || monitor.repo == primaryRepo))
        }.count
    }

    /// FE `compareMissingLast`: rows with a timestamp sort before rows
    /// without one (nil or empty, mirroring TS truthiness); two present
    /// timestamps compare via `areInIncreasingOrder`.
    private static func compareMissingLast(
        _ a: String?, _ b: String?,
        _ areInIncreasingOrder: (String, String) -> Bool
    ) -> Int {
        let aPresent = (a?.isEmpty == false) ? a : nil
        let bPresent = (b?.isEmpty == false) ? b : nil
        switch (aPresent, bPresent) {
        case let (x?, y?):
            if areInIncreasingOrder(x, y) { return -1 }
            if areInIncreasingOrder(y, x) { return 1 }
            return 0
        case (.some, .none): return -1
        case (.none, .some): return 1
        case (.none, .none): return 0
        }
    }
}

/// FE `toPRDisplayStatus`: raw wire `PullRequestStatus` variant name → pill
/// bucket; unknown future variants bucket as `closed`, matching the FE.
extension WorkspacePrPill.Status {
    nonisolated init(wire: String) {
        switch wire {
        case "Open": self = .open
        case "Merged": self = .merged
        case "Draft": self = .draft
        default: self = .closed
        }
    }
}
