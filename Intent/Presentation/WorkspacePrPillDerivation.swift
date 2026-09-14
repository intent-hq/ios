import SwiftUI

extension WorkspaceRowView {
    /// What the metadata line shows for PRs: the primary pill (nil renders
    /// no pill — exactly today's legacy behavior) and the "+N" count.
    struct PrIndicatorModel: Equatable {
        struct Pill: Equatable {
            let status: WorkspacePrPill.Status
            let number: Int?
        }

        let pill: Pill?
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
        if let prs = workspace.pullRequests, !prs.isEmpty {
            basePrs = prs
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

        let pill: PrIndicatorModel.Pill?
        if let primary {
            pill = PrIndicatorModel.Pill(status: primary.status, number: primary.number)
        } else if let legacy = workspace.prStatus.flatMap(legacyPillStatus) {
            pill = PrIndicatorModel.Pill(status: legacy, number: workspace.prNumber)
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

    /// Existing pill color mapping (Merged purple / Open green / Draft gray /
    /// Closed red), keyed by pill bucket instead of the raw wire string.
    static func pillColor(for status: WorkspacePrPill.Status) -> Color {
        switch status {
        case .merged: return .purple
        case .open: return .green
        case .draft: return .gray
        case .closed: return .red
        }
    }

    static func pillSystemImage(for status: WorkspacePrPill.Status) -> String {
        switch status {
        case .merged: return "arrow.triangle.merge"
        case .open: return "arrow.triangle.pull"
        case .draft: return "pencil.circle"
        case .closed: return "xmark.circle"
        }
    }
}
