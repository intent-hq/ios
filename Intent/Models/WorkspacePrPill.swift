import Foundation

nonisolated enum WorkspacePrPill {
    enum Status: String, Equatable {
        case closed
        case draft
        case merged
        case open
    }

    struct PillPr: Equatable {
        let number: Int
        let status: Status
        let createdAt: String?
        let updatedAt: String?
        let crossRepo: String?
        let monitorOnly: Bool

        init(
            number: Int,
            status: Status,
            createdAt: String? = nil,
            updatedAt: String? = nil,
            crossRepo: String? = nil,
            monitorOnly: Bool = false
        ) {
            self.number = number
            self.status = status
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.crossRepo = crossRepo
            self.monitorOnly = monitorOnly
        }

        init(_ pullRequest: WorkspacePullRequest) {
            self.init(
                number: pullRequest.number,
                status: Status(wire: pullRequest.status),
                createdAt: pullRequest.createdAt,
                updatedAt: pullRequest.updatedAt
            )
        }
    }

    static func monitorDisplayStatus(_ monitor: MonitoredPr) -> Status {
        let snapshotState = monitor.lastSnapshot?.state.lowercased()
        if snapshotState == "merged" { return .merged }
        if snapshotState == "closed" { return .closed }
        if monitor.lastSnapshot?.isDraft == true { return .draft }
        return monitor.state == .completed ? .closed : .open
    }

    static func mergeMonitoredPRs(
        _ basePRs: [PillPr],
        _ monitors: [MonitoredPr],
        workspaceRepo: String?
    ) -> [PillPr] {
        if monitors.isEmpty { return basePRs }
        var merged = basePRs
        for monitor in monitors {
            let sameRepo = workspaceRepo == nil || workspaceRepo?.isEmpty == true
                || monitor.repo == workspaceRepo
            let duplicatesExisting = merged.contains { pullRequest in
                sameRepo
                    ? pullRequest.crossRepo == nil && pullRequest.number == monitor.prNumber
                    : pullRequest.crossRepo == monitor.repo && pullRequest.number == monitor.prNumber
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

    static func selectPrimaryPr(_ prs: [PillPr]) -> PillPr? {
        let unmerged = prs.filter { $0.status == .open || $0.status == .draft }
        if !unmerged.isEmpty {
            return unmerged.min { left, right in
                let byCreated = compareMissingLast(left.createdAt, right.createdAt) { $0 < $1 }
                if byCreated != 0 { return byCreated < 0 }
                return left.number < right.number
            }
        }
        let merged = prs.filter { $0.status == .merged }
        if !merged.isEmpty {
            return merged.min { left, right in
                let byUpdated = compareMissingLast(left.updatedAt, right.updatedAt) { $0 > $1 }
                if byUpdated != 0 { return byUpdated < 0 }
                return left.number > right.number
            }
        }
        return prs.first
    }

    static func countOtherMonitors(
        _ monitors: [MonitoredPr],
        primaryPrNumber: Int?,
        repositoryOwner: String?,
        repositoryName: String?,
        primaryCrossRepo: String? = nil
    ) -> Int {
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

    private static func compareMissingLast(
        _ left: String?,
        _ right: String?,
        _ areInIncreasingOrder: (String, String) -> Bool
    ) -> Int {
        let leftPresent = (left?.isEmpty == false) ? left : nil
        let rightPresent = (right?.isEmpty == false) ? right : nil
        switch (leftPresent, rightPresent) {
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
