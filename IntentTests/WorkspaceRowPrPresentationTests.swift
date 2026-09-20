@testable import Intent
import SwiftUI
import Testing

extension WorkspaceRowPresentationTests {
    @Test func denseMetadataFixturePreservesLongFieldsAndConcurrentCues() {
        let workspace = makeWorkspace(
            title: "Refine the workspace list hierarchy without losing important metadata",
            repositoryName: "intent-hq/a-very-long-repository-name-for-layout-regressions",
            displayStatus: "in_progress",
            activity: "agent_running",
            attention: "unread",
            lastActivity: "2026-09-09T15:42:17Z",
            pullRequests: [
                WorkspacePullRequest(
                    number: 123_456_789,
                    status: "Open",
                    createdAt: "2026-09-01T00:00:00Z"
                ),
                WorkspacePullRequest(
                    number: 987_654_321,
                    status: "Merged",
                    updatedAt: "2026-09-02T00:00:00Z"
                )
            ]
        )

        let indicator = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])

        #expect(workspace.title.hasSuffix("important metadata"))
        #expect(workspace.repositoryName?.hasSuffix("layout-regressions") == true)
        #expect(workspace.lastActivity == "2026-09-09T15:42:17Z")
        #expect(workspace.pullRequests.count == 2)
        #expect(indicator.pill?.number == 123_456_789)
        #expect(
            WorkspaceStatusIconView.accessibilitySummary(for: workspace)
                == "In Progress, Active agent, Unread attention"
        )
    }

    @Test func densePrBadgeInputsPreserveLongIdentifierAndLargeCount() {
        let workspace = makeWorkspace(
            displayStatus: "in_progress",
            pullRequests: [
                WorkspacePullRequest(
                    number: 123_456_789,
                    status: "Open",
                    createdAt: "2026-08-01T00:00:00Z"
                )
            ]
        )
        let monitors = (1...100).map { index in
            makeMonitor(number: 900_000_000 + index)
        }

        let indicator = WorkspaceRowView.derivePrIndicator(
            workspace: workspace,
            monitors: monitors
        )

        #expect(indicator.pill?.number == 123_456_789)
        #expect(indicator.otherMonitorCount == 100)
        #expect(
            WorkspaceRowView.additionalPullRequestsAccessibilityLabel(
                indicator.otherMonitorCount
            ) == "100 additional pull requests"
        )
    }

    @Test func adaptivePrBadgeInputsPreserveEmptyAndSingleStates() {
        let empty = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(displayStatus: nil),
            monitors: []
        )
        let single = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(
                displayStatus: nil,
                pullRequests: [WorkspacePullRequest(number: 123_456_789, status: "Open")]
            ),
            monitors: []
        )

        #expect(empty.pill == nil)
        #expect(empty.otherMonitorCount == 0)
        #expect(single.pill?.number == 123_456_789)
        #expect(single.otherMonitorCount == 0)
    }

    @Test func adaptivePrBadgeInputsPreserveMonitorOnlyAndNumberlessStates() {
        let monitorOnly = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(displayStatus: nil),
            monitors: [makeMonitor(number: 231)]
        )
        let numberless = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(displayStatus: nil, prStatus: "Open"),
            monitors: []
        )

        #expect(monitorOnly.pill?.number == 231)
        #expect(monitorOnly.otherMonitorCount == 0)
        #expect(numberless.pill?.status == .open)
        #expect(numberless.pill?.number == nil)
    }
}
