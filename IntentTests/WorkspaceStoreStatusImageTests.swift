@testable import Intent
import Testing

@MainActor
struct WorkspaceStoreStatusImageTests {
    @Test func inPlaceUpdatersKeepStatusImageAssetId() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [workspace()]
        store.clearUnreadAttentionLocally(workspaceId: "ws-1")
        #expect(store.workspaces[0].statusImageAssetId == "asset-1.png")
        #expect(store.workspaces[0].statusMessage == "Ready for review")
        store.updateWaiting(workspaceId: "ws-1", waiting: true)
        #expect(store.workspaces[0].statusImageAssetId == "asset-1.png")
        #expect(store.workspaces[0].statusMessage == "Ready for review")
        store.updateLastActivity(workspaceId: "ws-1", lastActivity: "2026-09-01T00:00:00Z")
        #expect(store.workspaces[0].statusImageAssetId == "asset-1.png")
        #expect(store.workspaces[0].statusMessage == "Ready for review")
    }

    private func workspace() -> Workspace {
        Workspace(
            id: "ws-1",
            title: "Workspace",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: "needs_attention",
            attention: "unread",
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            statusImageAssetId: "asset-1.png",
            statusMessage: "Ready for review"
        )
    }
}
