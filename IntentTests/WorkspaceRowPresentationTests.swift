@testable import Intent
import SwiftUI
import Testing
import UIKit

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
            displayStatus: "in_progress",
            title: "Refine the workspace list hierarchy without losing important metadata",
            repositoryName: "intent-hq/a-very-long-repository-name-for-layout-regressions",
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
        #expect(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(
            indicator.otherMonitorCount
        ) == "100 additional pull requests")
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
            "100 additional pull requests"
        ])
        print("SYNTHETIC PR badge fit geometry: \(fit)")
        print("SYNTHETIC PR badge fallback geometry: \(fallback)")
    }

    @Test func accessibilityTraversalIncludesDynamicContainerElements() {
        let container = DynamicAccessibilityContainer()

        #expect(container.accessibilityElements == nil)
        #expect(accessibilityElements(in: container).map(\.accessibilityLabel) == [
            "Dynamic container element"
        ])
    }

    @Test func accessibilityTraversalPrefersPropertyElementsOverEmptyIndexLookup() {
        let container = ConflictingAccessibilityContainer()
        let element = UIAccessibilityElement(accessibilityContainer: container)
        element.accessibilityLabel = "Property container element"
        container.accessibilityElements = [element]

        #expect(accessibilityElements(in: container).map(\.accessibilityLabel) == [
            "Property container element"
        ])
    }

    @Test func accessibilityGraphDiagnosticsRedactContentAndTraverseNonViewContainers() {
        let container = NonViewAccessibilityContainer()
        container.dynamicElement.accessibilityLabel = "Expected label"
        container.dynamicElement.accessibilityValue = "private value"
        container.dynamicElement.accessibilityHint = "private hint"

        let snapshot = accessibilityGraphSnapshot(
            root: container,
            expectedLabels: ["Expected label", "Other expected label"]
        )

        #expect(snapshot.contains("path=root.dynamic[0]"))
        #expect(snapshot.contains("labelPresent=true labelMatches=[true,false]"))
        #expect(!snapshot.contains("Expected label"))
        #expect(!snapshot.contains("private value"))
        #expect(!snapshot.contains("private hint"))
    }

    @Test func accessibilityGraphDiagnosticsAreCycleSafeAndBounded() {
        let cycle = NSObject()
        cycle.accessibilityElements = [cycle]
        #expect(accessibilityGraphSnapshot(
            root: cycle,
            expectedLabels: []
        ).split(separator: "\n").count == 1)
        cycle.accessibilityElements = nil

        let wideRoot = NSObject()
        wideRoot.accessibilityElements = (0..<100).map { _ in NSObject() }
        let wideSnapshot = accessibilityGraphSnapshot(root: wideRoot, expectedLabels: [])
        #expect(wideSnapshot.split(separator: "\n").count == 64)
        #expect(wideSnapshot.count <= 32_768)

        let deepRoot = NSObject()
        var tail = deepRoot
        for _ in 0..<12 {
            let child = NSObject()
            tail.accessibilityElements = [child]
            tail = child
        }
        let deepSnapshot = accessibilityGraphSnapshot(root: deepRoot, expectedLabels: [])
        #expect(deepSnapshot.contains("depth=8"))
        #expect(!deepSnapshot.contains("depth=9"))
    }

    @Test func accessibilityGraphObservationCannotRescueAnInitialMissingLabel() {
        let element = UIAccessibilityElement(accessibilityContainer: NSObject())
        let initialBadges = initialBadgeFrames(labels: ["Expected label"], elements: [element])

        element.accessibilityLabel = "Expected label"

        #expect(initialBadges[0]?.label == nil)
    }

    @Test func statusSummaryPreservesConcurrentStatusCues() {
        let workspace = makeWorkspace(
            displayStatus: "needs_attention",
            activity: "agent_running",
            attention: "unread"
        )

        #expect(WorkspaceStatusIconView.accessibilitySummary(for: workspace)
            == "Needs Attention, Active agent, Unread attention")
    }

    @Test func waitingSummaryAppearsOnlyWhenWaitingCueIsVisible() {
        let waiting = makeWorkspace(displayStatus: "idle", waiting: true)
        let running = makeWorkspace(
            displayStatus: "idle",
            activity: "agent_running",
            waiting: true
        )

        #expect(WorkspaceStatusIconView.accessibilitySummary(for: waiting)
            == "Idle, Waiting")
        #expect(WorkspaceStatusIconView.accessibilitySummary(for: running)
            == "Idle, Active agent")
    }
}

extension WorkspaceRowPresentationTests {
    private func makeWorkspace(
        displayStatus: String?,
        title: String = "Workspace",
        repositoryName: String? = nil,
        activity: String? = nil,
        attention: String? = nil,
        waiting: Bool = false,
        lastActivity: String? = nil,
        prStatus: String? = nil,
        prNumber: Int? = nil,
        pullRequests: [WorkspacePullRequest] = []
    ) -> Workspace {
        Workspace(
            id: "ws-1",
            title: title,
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: activity,
            displayStatus: displayStatus,
            attention: attention,
            waiting: waiting,
            lastActivity: lastActivity,
            updatedAt: nil,
            repositoryOwner: "intent-hq",
            repositoryName: repositoryName,
            prStatus: prStatus,
            prNumber: prNumber,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            pullRequests: pullRequests
        )
    }

    private func makeMonitor(number: Int) -> MonitoredPr {
        MonitoredPr(
            monitorId: "prm-\(number)",
            workspaceId: "ws-1",
            agentId: "agent-1",
            repo: "intent-hq/intent",
            prNumber: number,
            state: .active,
            pendingChanges: [],
            hasPendingChanges: false,
            createdAt: "2026-09-01T00:00:00Z",
            updatedAt: nil,
            pendingSince: nil,
            lastChangeAt: nil,
            lastPolledAt: nil,
            lastError: nil,
            title: nil,
            url: nil,
            lastSnapshot: nil
        )
    }

    private enum RenderingMetrics {
        static let pullRequestNumber = 123_456_789
        static let hostHeight: CGFloat = 300
        static let maximumClassNameLength = 80
    }

    private struct RenderedBadges {
        let hostFrame: CGRect
        let badges: [(label: String, frame: CGRect)]
    }
    private func renderBadges(width: CGFloat) throws -> RenderedBadges {
        try autoreleasepool {
            try renderBadgesInCurrentAutoreleasePool(width: width)
        }
    }
    private func renderBadgesInCurrentAutoreleasePool(width: CGFloat) throws -> RenderedBadges {
        let indicator = WorkspaceRowView.PrIndicatorModel(
            pill: .init(status: .merged, number: RenderingMetrics.pullRequestNumber),
            otherMonitorCount: 100
        )
        let rootView = WorkspaceRowView.PullRequestBadges(
            indicator: indicator,
            colorScheme: .light,
            colorSchemeContrast: .standard,
            expanded: true
        )
            .environment(\.accessibilityEnabled, true)
            .environment(\.dynamicTypeSize, .accessibility3)
            .frame(width: width, height: RenderingMetrics.hostHeight, alignment: .topLeading)
        let window = UIWindow(frame: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: RenderingMetrics.hostHeight
        ))
        let controller = UIHostingController(rootView: rootView)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let labels = ["Merged pull request #123456789", "100 additional pull requests"]
        let elements = accessibilityElements(in: controller.view)
        let initialBadges = initialBadgeFrames(labels: labels, elements: elements)
        if initialBadges.contains(where: { $0?.label == nil }) {
            let immediate = accessibilityGraphSnapshot(root: window, expectedLabels: labels)
            print("SYNTHETIC PR badge accessibility graph immediate:\n\(immediate)")
        }
        let badges = try initialBadges.map { initialBadge in
            try #require(initialBadge)
        }
        let hostFrame = controller.view.convert(controller.view.bounds, to: nil)
        return RenderedBadges(hostFrame: hostFrame, badges: badges)
    }
    private func initialBadgeFrames(
        labels: [String],
        elements: [NSObject]
    ) -> [(label: String, frame: CGRect)?] {
        labels.map { label in
            elements.first { $0.accessibilityLabel == label }.map { element in
                (label: label, frame: element.accessibilityFrame)
            }
        }
    }
    private func accessibilityElements(in view: UIView) -> [NSObject] {
        let property = (view.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        let elementCount = view.accessibilityElementCount()
        let direct: [NSObject]
        if !property.isEmpty {
            direct = property
        } else if elementCount == NSNotFound {
            direct = []
        } else {
            direct = (0..<elementCount).compactMap { index in
                view.accessibilityElement(at: index) as? NSObject
            }
        }
        let ownElements: [NSObject]
        if view.isAccessibilityElement {
            ownElements = [view]
        } else {
            ownElements = direct
        }
        return ownElements + view.subviews.flatMap(accessibilityElements(in:))
    }
    private func accessibilityGraphSnapshot(
        root: NSObject,
        expectedLabels: [String],
        maxNodes: Int = 64,
        maxDepth: Int = 8,
        maxOutputCharacters: Int = 32_768
    ) -> String {
        var visited: Set<ObjectIdentifier> = []
        var lines: [String] = []

        func visit(_ object: NSObject, path: String, depth: Int) {
            guard depth <= maxDepth, visited.count < maxNodes,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }

            let propertyChildren = (object.accessibilityElements ?? [])
                .prefix(maxNodes)
                .compactMap { $0 as? NSObject }
            let elementCount = object.accessibilityElementCount()
            let dynamicChildren: [NSObject]
            if elementCount == NSNotFound || elementCount < 0 {
                dynamicChildren = []
            } else {
                dynamicChildren = (0..<min(elementCount, maxNodes)).compactMap { index in
                    object.accessibilityElement(at: index) as? NSObject
                }
            }
            let subviews = (object as? UIView).map { view in
                Array(view.subviews.prefix(maxNodes))
            } ?? []
            lines.append(accessibilityGraphLine(.init(
                object: object,
                path: path,
                depth: depth,
                expectedLabels: expectedLabels,
                propertyChildCount: propertyChildren.count,
                dynamicChildCount: dynamicChildren.count,
                subviewCount: subviews.count,
                elementCount: elementCount
            )))

            guard depth < maxDepth else { return }
            for (index, child) in propertyChildren.enumerated() {
                visit(child, path: "\(path).property[\(index)]", depth: depth + 1)
            }
            for (index, child) in dynamicChildren.enumerated() {
                visit(child, path: "\(path).dynamic[\(index)]", depth: depth + 1)
            }
            for (index, child) in subviews.enumerated() {
                visit(child, path: "\(path).subview[\(index)]", depth: depth + 1)
            }
        }

        visit(root, path: "root", depth: 0)
        return String(lines.joined(separator: "\n").prefix(maxOutputCharacters))
    }
    private struct AccessibilityGraphFacts {
        let object: NSObject
        let path: String
        let depth: Int
        let expectedLabels: [String]
        let propertyChildCount: Int
        let dynamicChildCount: Int
        let subviewCount: Int
        let elementCount: Int
    }
    private func accessibilityGraphLine(_ facts: AccessibilityGraphFacts) -> String {
        let label = facts.object.accessibilityLabel
        let labelMatches = facts.expectedLabels.map { label == $0 }.map(String.init).joined(separator: ",")
        let countDescription = facts.elementCount == NSNotFound ? "NSNotFound" : "\(facts.elementCount)"
        let className = String(String(describing: type(of: facts.object)).prefix(RenderingMetrics.maximumClassNameLength))
        let viewFacts = (facts.object as? UIView).map { view in
            "attached=\(view.window != nil) hidden=\(view.isHidden) bounds=\(view.bounds)"
        } ?? "attached=na hidden=na bounds=na"
        return "depth=\(facts.depth) path=\(facts.path) class=\(className) \(viewFacts) "
            + "frame=\(facts.object.accessibilityFrame) elementCount=\(countDescription) "
            + "children=[property:\(facts.propertyChildCount),dynamic:\(facts.dynamicChildCount),"
            + "subviews:\(facts.subviewCount)] labelPresent=\(label != nil) labelMatches=[\(labelMatches)]"
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

    private final class ConflictingAccessibilityContainer: UIView {
        override func accessibilityElementCount() -> Int { 1 }

        override func accessibilityElement(at _: Int) -> Any? { nil }
    }

    private final class NonViewAccessibilityContainer: NSObject {
        lazy var dynamicElement = UIAccessibilityElement(accessibilityContainer: self)

        override func accessibilityElementCount() -> Int { 1 }

        override func accessibilityElement(at index: Int) -> Any? {
            index == 0 ? dynamicElement : nil
        }

        override func index(ofAccessibilityElement element: Any) -> Int {
            element as AnyObject === dynamicElement ? 0 : NSNotFound
        }
    }
}
