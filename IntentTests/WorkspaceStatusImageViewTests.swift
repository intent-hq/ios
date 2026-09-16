import Foundation
import Testing
@testable import Intent

/// Pure mapping behind the workspace status image (intent-hq/intent#3868):
/// which workspaces render one, how the fetch is keyed so replacements and
/// removals refresh, and how each placement degrades when the asset fails.
struct WorkspaceStatusImageViewTests {
    private typealias Layout = WorkspaceStatusImageLayout

    private func workspace(statusImageAssetId: String?) -> Workspace {
        Workspace(
            id: "ws-1", title: "W", branch: nil, baseRef: nil, status: nil, activity: nil,
            displayStatus: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: nil,
            repositoryName: nil, prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil,
            taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil,
            statusImageAssetId: statusImageAssetId)
    }

    @Test func normalizedAssetIdDropsBlankAndMissingValues() {
        #expect(Layout.normalizedAssetId(nil) == nil)
        #expect(Layout.normalizedAssetId("") == nil)
        #expect(Layout.normalizedAssetId("  \n") == nil)
        #expect(Layout.normalizedAssetId("m1-abc.png") == "m1-abc.png")
        #expect(Layout.normalizedAssetId(" m1-abc.png ") == "m1-abc.png")
    }

    @Test func unsetWorkspaceRendersNoImage() {
        #expect(Layout.assetId(for: nil) == nil)
        #expect(Layout.assetId(for: workspace(statusImageAssetId: nil)) == nil)
        #expect(Layout.assetId(for: workspace(statusImageAssetId: "m1-abc.png")) == "m1-abc.png")
    }

    @Test func loadKeyChangesWhenTheAssetIsReplacedOrRetried() {
        let base = Layout.loadKey(workspaceId: "ws-1", assetId: "a.png", attempt: 0)
        #expect(base == Layout.loadKey(workspaceId: "ws-1", assetId: "a.png", attempt: 0))
        #expect(base != Layout.loadKey(workspaceId: "ws-1", assetId: "b.png", attempt: 0))
        #expect(base != Layout.loadKey(workspaceId: "ws-2", assetId: "a.png", attempt: 0))
        #expect(base != Layout.loadKey(workspaceId: "ws-1", assetId: "a.png", attempt: 1))
    }

    @Test func cardHidesAFailedImageWhileDetailShowsARetryState() {
        // The list row has no room for an error affordance: a broken asset
        // collapses to the plain row (desktop card parity). The detail
        // header keeps a clear, non-broken placeholder the user can retry.
        #expect(Layout.hidesOnFailure(.card))
        #expect(!Layout.hidesOnFailure(.detail))
    }

    @Test func placementsHaveDistinctAccessibilityIdentifiers() {
        #expect(Layout.accessibilityIdentifier(for: .card) == "workspaceRow.statusImage")
        #expect(Layout.accessibilityIdentifier(for: .detail) == "workspaceDetail.statusImage")
        #expect(Layout.accessibilityLabel(for: .card) == "Workspace status image")
        #expect(Layout.accessibilityLabel(for: .detail) == "Workspace status image")
    }

    @Test func detailImageIsBoundedAndCardThumbnailIsSquare() {
        #expect(Layout.detailMaxHeight > 0)
        #expect(Layout.cardThumbnailSide > 0)
        #expect(Layout.cardThumbnailSide < Layout.detailMaxHeight)
    }
}
