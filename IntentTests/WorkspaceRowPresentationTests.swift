import SwiftUI
import Testing
import UIKit
@testable import Intent

@MainActor
struct WorkspaceRowPresentationTests {
    @Test func metadataReflowsOnlyAtAccessibilitySizes() {
        #expect(!WorkspaceRowView.usesExpandedMetadataLayout(for: .xxxLarge))
        #expect(WorkspaceRowView.usesExpandedMetadataLayout(for: .accessibility1))
        #expect(WorkspaceRowView.usesExpandedMetadataLayout(for: .accessibility5))
    }

    @Test func accessibilitySizesDoNotLimitLongTitles() {
        #expect(WorkspaceRowView.titleLineLimit(for: .xxxLarge) == 2)
        #expect(WorkspaceRowView.titleLineLimit(for: .accessibility1) == nil)
        #expect(WorkspaceRowView.titleLineLimit(for: .accessibility5) == nil)
    }

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
                    number: 123_456_789, status: "Open",
                    createdAt: "2026-09-01T00:00:00Z"),
                WorkspacePullRequest(
                    number: 987_654_321, status: "Merged",
                    updatedAt: "2026-09-02T00:00:00Z"),
            ])

        let indicator = WorkspaceRowView.derivePrIndicator(workspace: workspace, monitors: [])

        #expect(workspace.title.hasSuffix("important metadata"))
        #expect(workspace.repositoryName?.hasSuffix("layout-regressions") == true)
        #expect(workspace.lastActivity == "2026-09-09T15:42:17Z")
        #expect(workspace.pullRequests?.count == 2)
        #expect(indicator.pill?.number == 123_456_789)
        #expect(WorkspaceStatusIconView.accessibilitySummary(for: workspace)
            == "In Progress, Active agent, Unread attention")
    }

    @Test func additionalPullRequestCountHasReadableAccessibilityLabel() {
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(1)
            == "1 additional pull request")
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(3)
            == "3 additional pull requests")
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(100)
            == "100 additional pull requests")
    }

    @Test func densePrBadgeInputsPreserveLongIdentifierAndLargeCount() {
        let workspace = makeWorkspace(
            displayStatus: "in_progress",
            pullRequests: [
                WorkspacePullRequest(
                    number: 123_456_789, status: "Open",
                    createdAt: "2026-08-01T00:00:00Z"),
            ])
        let monitors = (1...100).map {
            makeMonitor(number: 900_000_000 + $0)
        }

        let indicator = WorkspaceRowView.derivePrIndicator(
            workspace: workspace, monitors: monitors)

        #expect(indicator.pill?.number == 123_456_789)
        #expect(indicator.otherMonitorCount == 100)
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(
            indicator.otherMonitorCount) == "100 additional pull requests")
    }

    @Test func adaptivePrBadgeInputsPreserveEmptyAndSingleStates() {
        let empty = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(displayStatus: nil), monitors: [])
        let single = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(
                displayStatus: nil,
                pullRequests: [WorkspacePullRequest(number: 123_456_789, status: "Open")]),
            monitors: [])

        #expect(empty.pill == nil)
        #expect(empty.otherMonitorCount == 0)
        #expect(single.pill?.number == 123_456_789)
        #expect(single.otherMonitorCount == 0)
    }

    @Test func adaptivePrBadgeInputsPreserveMonitorOnlyAndNumberlessStates() {
        let monitorOnly = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(displayStatus: nil),
            monitors: [makeMonitor(number: 231)])
        let numberless = WorkspaceRowView.derivePrIndicator(
            workspace: makeWorkspace(displayStatus: nil, prStatus: "Open"),
            monitors: [])

        #expect(monitorOnly.pill?.number == 231)
        #expect(monitorOnly.otherMonitorCount == 0)
        #expect(numberless.pill?.status == .open)
        #expect(numberless.pill?.number == nil)
    }

    @Test func renderedPrBadgesFitThenFallBackInsideSyntheticHost() throws {
        let fit = try renderBadges(width: 600)
        let combinedIdealWidth = fit.badges[0].frame.union(fit.badges[1].frame).width
        let largestBadgeWidth = fit.badges.map { $0.frame.width }.max() ?? 0
        let fallbackWidth = ceil(largestBadgeWidth) + 1
        let renderedFrameTolerance: CGFloat = 0.001

        #expect(abs(fit.badges[0].frame.midY - fit.badges[1].frame.midY)
            <= renderedFrameTolerance)
        #expect(fit.badges[0].frame.maxX < fit.badges[1].frame.minX)
        #expect(combinedIdealWidth <= fit.hostFrame.width)
        #expect(fallbackWidth < combinedIdealWidth)
        #expect(fit.badges.allSatisfy { $0.frame.width <= fallbackWidth })
        #expect(fit.badges.allSatisfy { fit.hostFrame.contains($0.frame) })

        let fallback = try renderBadges(width: fallbackWidth)

        #expect(fallback.badges[0].frame.minX == fallback.badges[1].frame.minX)
        #expect(fallback.badges[0].frame.maxY < fallback.badges[1].frame.minY)
        #expect(fallback.badges.allSatisfy { fallback.hostFrame.contains($0.frame) })
        #expect(fallback.badges.map { $0.label } == [
            "Merged pull request #123456789",
            "100 additional pull requests",
        ])
        print("SYNTHETIC PR badge fit geometry: \(fit)")
        print("SYNTHETIC PR badge fallback geometry: \(fallback)")
    }

    @Test func accessibilityTraversalIncludesDynamicContainerElements() {
        let container = DynamicAccessibilityContainer()

        #expect(container.accessibilityElements == nil)
        #expect(accessibilityElements(in: container).map(\.accessibilityLabel) == [
            "Dynamic container element",
        ])
    }

    @Test func statusSummaryPreservesConcurrentStatusCues() {
        let workspace = makeWorkspace(
            displayStatus: "needs_attention",
            activity: "agent_running",
            attention: "unread")

        #expect(WorkspaceStatusIconView.accessibilitySummary(for: workspace)
            == "Needs Attention, Active agent, Unread attention")
    }

    @Test func waitingSummaryAppearsOnlyWhenWaitingCueIsVisible() {
        let waiting = makeWorkspace(displayStatus: "idle", waiting: true)
        let running = makeWorkspace(
            displayStatus: "idle", activity: "agent_running", waiting: true)

        #expect(WorkspaceStatusIconView.accessibilitySummary(for: waiting)
            == "Idle, Waiting")
        #expect(WorkspaceStatusIconView.accessibilitySummary(for: running)
            == "Idle, Active agent")
    }

    private func makeWorkspace(
        title: String = "Workspace",
        repositoryName: String? = nil,
        displayStatus: String?,
        activity: String? = nil,
        attention: String? = nil,
        waiting: Bool = false,
        lastActivity: String? = nil,
        prStatus: String? = nil,
        prNumber: Int? = nil,
        pullRequests: [WorkspacePullRequest]? = nil
    ) -> Workspace {
        Workspace(
            id: "ws-1", title: title, branch: nil, baseRef: nil,
            status: nil, activity: activity, displayStatus: displayStatus,
            attention: attention, waiting: waiting,
            lastActivity: lastActivity, updatedAt: nil,
            repositoryOwner: "intent-hq", repositoryName: repositoryName,
            prStatus: prStatus, prNumber: prNumber,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil, taskStatsCompleted: nil,
            taskStatsInProgress: nil, agentSummaryCount: nil,
            agentSummaryAgents: nil, pullRequests: pullRequests)
    }

    private func makeMonitor(number: Int) -> MonitoredPr {
        MonitoredPr(
            monitorId: "prm-\(number)", workspaceId: "ws-1", agentId: "agent-1",
            repo: "intent-hq/intent", prNumber: number, state: .active,
            pendingChanges: [], hasPendingChanges: false,
            createdAt: "2026-09-01T00:00:00Z", updatedAt: nil, pendingSince: nil,
            lastChangeAt: nil, lastPolledAt: nil, lastError: nil,
            title: nil, url: nil, lastSnapshot: nil)
    }

    private struct RenderedBadges {
        let hostFrame: CGRect
        let badges: [(label: String, frame: CGRect)]
    }

    private func renderBadges(width: CGFloat) throws -> RenderedBadges {
        try autoreleasepool {
            let indicator = WorkspaceRowView.PrIndicatorModel(
                pill: .init(status: .merged, number: 123_456_789),
                otherMonitorCount: 100)
            let height: CGFloat = 300
            let rootView = WorkspaceRowView.PullRequestBadges(
                indicator: indicator,
                colorScheme: .light,
                colorSchemeContrast: .standard,
                expanded: true)
                .environment(\.dynamicTypeSize, .accessibility3)
                .frame(width: width, height: height, alignment: .topLeading)
            let controller = UIHostingController(rootView: rootView)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
            controller.view.frame = window.bounds
            // This synthetic container owns attachment, so it must forward a matched lifecycle.
            controller.beginAppearanceTransition(true, animated: false)
            window.addSubview(controller.view)
            window.isHidden = false
            controller.endAppearanceTransition()
            defer {
                controller.beginAppearanceTransition(false, animated: false)
                controller.view.removeFromSuperview()
                window.isHidden = true
                controller.endAppearanceTransition()
            }
            controller.view.layoutIfNeeded()

            let labels = ["Merged pull request #123456789", "100 additional pull requests"]
            let elements = accessibilityElements(in: controller.view)
            let badges = try labels.map { label in
                let element = try #require(elements.first { $0.accessibilityLabel == label })
                return (label, element.accessibilityFrame)
            }
            let hostFrame = controller.view.convert(controller.view.bounds, to: nil)
            return RenderedBadges(hostFrame: hostFrame, badges: badges)
        }
    }

    private func accessibilityElements(in view: UIView) -> [NSObject] {
        let elementCount = view.accessibilityElementCount()
        let direct = elementCount == NSNotFound
            ? (view.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            : (0..<elementCount).compactMap {
                view.accessibilityElement(at: $0) as? NSObject
            }
        return (view.isAccessibilityElement ? [view] : direct)
            + view.subviews.flatMap(accessibilityElements(in:))
    }

    private final class DynamicAccessibilityContainer: UIView {
        private lazy var dynamicElement: UIAccessibilityElement = {
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = "Dynamic container element"
            return element
        }()

        override func accessibilityElementCount() -> Int { 1 }

        override func accessibilityElement(at index: Int) -> Any? {
            index == 0 ? dynamicElement : nil
        }

        override func index(ofAccessibilityElement element: Any) -> Int {
            element as AnyObject === dynamicElement ? 0 : NSNotFound
        }
    }
}
