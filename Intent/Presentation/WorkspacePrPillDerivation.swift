import SwiftUI

extension WorkspaceRowView {
    struct PrIndicatorPill: Equatable {
        let status: WorkspacePrPill.Status
        let number: Int?
    }

    /// What the metadata line shows for PRs: the primary pill (nil renders
    /// no pill — exactly today's legacy behavior) and the "+N" count.
    struct PrIndicatorModel: Equatable {
        let pill: PrIndicatorPill?
        let otherMonitorCount: Int
    }

    /// FE `WorkspaceCard` composition (PROTOCOL §6.9): primary =
    /// `selectPrimaryPr` over `pullRequests` merged with the workspace's
    /// monitors; legacy `prStatus`/`prNumber` only when the pool is empty;
    /// "+N" = `countOtherMonitors` against the primary's repo-qualified
    /// number. Like FE `mapWorkspacePRs`, an empty/absent `pullRequests`
    /// falls back to the single `activePullRequest` row before merging.
    static func derivePrIndicator(
        workspace: Workspace,
        monitors: [MonitoredPr]
    ) -> PrIndicatorModel {
        var workspaceRepo: String?
        if let owner = workspace.repositoryOwner, let name = workspace.repositoryName,
           !owner.isEmpty, !name.isEmpty {
            workspaceRepo = "\(owner)/\(name)"
        }
        let basePrs: [WorkspacePullRequest]
        if !workspace.pullRequests.isEmpty {
            basePrs = workspace.pullRequests
        } else if let activePr = workspace.activePullRequest {
            basePrs = [activePr]
        } else {
            basePrs = []
        }
        let base = basePrs.map(WorkspacePrPill.PillPr.init)
        let pool = WorkspacePrPill.mergeMonitoredPRs(
            base,
            monitors,
            workspaceRepo: workspaceRepo
        )
        let primary = WorkspacePrPill.selectPrimaryPr(pool)

        let pill: PrIndicatorPill?
        if let primary {
            pill = PrIndicatorPill(status: primary.status, number: primary.number)
        } else if let legacy = workspace.prStatus.flatMap(legacyPillStatus) {
            pill = PrIndicatorPill(status: legacy, number: workspace.prNumber)
        } else {
            pill = nil
        }

        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: primary?.number ?? workspace.prNumber,
            repositoryOwner: workspace.repositoryOwner,
            repositoryName: workspace.repositoryName,
            primaryCrossRepo: primary?.crossRepo
        )
        return PrIndicatorModel(pill: pill, otherMonitorCount: count)
    }

    /// Legacy `workspace.prStatus` fallback: only the four known wire strings
    /// render a pill (unknown values hide it, exactly as before).
    nonisolated static func legacyPillStatus(_ raw: String) -> WorkspacePrPill.Status? {
        switch raw {
        case "Merged": return .merged
        case "Open": return .open
        case "Draft": return .draft
        case "Closed": return .closed
        default: return nil
        }
    }

    static func pillImage(for status: WorkspacePrPill.Status) -> ImageResource {
        switch status {
        case .merged: return .pullRequestMerged
        case .open: return .pullRequestOpen
        case .draft: return .pullRequestDraft
        case .closed: return .pullRequestClosed
        }
    }
}
