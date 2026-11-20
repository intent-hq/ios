import Foundation

extension WorkspaceStore {
    func updateLastActivity(workspaceId: String, lastActivity: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[index].lastActivity != lastActivity else { return }
        apply(at: index) { Self.patched($0, .lastActivity(lastActivity)) }
    }

    func updateWaiting(workspaceId: String, waiting: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[index].waiting != waiting else { return }
        apply(at: index) { Self.patched($0, .waiting(waiting)) }
    }

    func clearUnreadAttentionLocally(workspaceId: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[index].attention == "unread" else { return }
        apply(at: index) { Self.patched($0, .attention("none")) }
    }

    private func apply(at index: Int, _ patch: (Workspace) -> Workspace) {
        let updated = patch(workspaces[index])
        workspaces[index] = updated
        guard let reconciler = workspaceReconciler else { return }
        if snapshotFiller.isFilling {
            reconciler.patch(id: updated.id, patch)
        } else {
            reconciler.seed(id: updated.id, value: updated)
        }
    }

    private enum RowPatch {
        case attention(String)
        case lastActivity(String)
        case waiting(Bool)
    }

    private static func patched(_ workspace: Workspace, _ patch: RowPatch) -> Workspace {
        var attention = workspace.attention
        var waiting = workspace.waiting
        var lastActivity = workspace.lastActivity
        switch patch {
        case .attention(let value): attention = value
        case .lastActivity(let value): lastActivity = value
        case .waiting(let value): waiting = value
        }
        return Workspace(
            id: workspace.id,
            title: workspace.title,
            branch: workspace.branch,
            baseRef: workspace.baseRef,
            status: workspace.status,
            activity: workspace.activity,
            displayStatus: workspace.displayStatus,
            attention: attention,
            waiting: waiting,
            lastActivity: lastActivity,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            repositoryOwner: workspace.repositoryOwner,
            repositoryName: workspace.repositoryName,
            prStatus: workspace.prStatus,
            prNumber: workspace.prNumber,
            diffSummaryTotalFiles: workspace.diffSummaryTotalFiles,
            taskStatsTotal: workspace.taskStatsTotal,
            taskStatsCompleted: workspace.taskStatsCompleted,
            taskStatsInProgress: workspace.taskStatsInProgress,
            agentSummaryCount: workspace.agentSummaryCount,
            agentSummaryAgents: workspace.agentSummaryAgents,
            pullRequests: workspace.pullRequests,
            agentSummaryWasReported: workspace.agentSummaryWasReported,
            pullRequestsWereReported: workspace.pullRequestsWereReported,
            activePullRequest: workspace.activePullRequest,
            statusImageAssetId: workspace.statusImageAssetId,
            statusMessage: workspace.statusMessage
        )
    }
}
