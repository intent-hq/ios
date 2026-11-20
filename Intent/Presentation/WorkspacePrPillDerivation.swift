import SwiftUI

extension WorkspaceRowView {
    struct PrIndicatorPill: Equatable {
        let status: WorkspacePrPill.Status
        let number: Int?
    }

    struct PrIndicatorModel: Equatable {
        let pill: PrIndicatorPill?
        let otherMonitorCount: Int
    }

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
