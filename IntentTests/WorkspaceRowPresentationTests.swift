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

    // Gated, not skipped silently: on the simulator the wrapper guarantees the
    // accessibility tree, so the condition is always true there and a missing
    // badge is a real failure. Only a physical-device run with accessibility off
    // is excluded, by probing the host rather than guessing.
    @Test(.enabled(
        Comment(rawValue:
            "SwiftUI publishes its accessibility tree only when accessibility is enabled "
                + "for the process (scripts/xcodebuild.sh enables it on the simulator; a "
                + "physical-device unit-test run needs VoiceOver or an XCUITest session)"),
        { await SyntheticBadgeHost.publishesAccessibilityTree() }))
    func renderedPrBadgesFitThenFallBackInsideSyntheticHost() throws {
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
        #expect(fit.badges.map { $0.label } == Self.badgeLabels)

        let fallback = try renderBadges(width: fallbackWidth)

        #expect(fallback.badges[0].frame.minX == fallback.badges[1].frame.minX)
        #expect(fallback.badges[0].frame.maxY < fallback.badges[1].frame.minY)
        #expect(fallback.badges.allSatisfy { fallback.hostFrame.contains($0.frame) })
        #expect(fallback.badges.map { $0.label } == Self.badgeLabels)
        print("SYNTHETIC PR badge fit geometry: \(fit)")
        print("SYNTHETIC PR badge fallback geometry: \(fallback)")
    }

    @Test func badgeIdentifiersAreStableAndDistinct() {
        #expect(WorkspaceRowView.BadgeIdentifier.pullRequest == "workspaceRow.prBadge")
        #expect(WorkspaceRowView.BadgeIdentifier.additionalPullRequests
            == "workspaceRow.prBadge.additional")
    }

    @Test func accessibilityTraversalIncludesDynamicContainerElements() {
        let container = DynamicAccessibilityContainer()

        #expect(container.accessibilityElements == nil)
        #expect(SyntheticBadgeHost.accessibilityElements(in: container)
            .map(\.accessibilityLabel) == ["Dynamic container element"])
    }

    @Test func accessibilityIdentifierReadsOnlyObjectsThatPublishOne() {
        let element = UIAccessibilityElement(accessibilityContainer: NSObject())
        element.accessibilityIdentifier = "expected.identifier"
        let view = UIView()
        view.accessibilityIdentifier = "expected.view"

        #expect(SyntheticBadgeHost.accessibilityIdentifier(of: element) == "expected.identifier")
        #expect(SyntheticBadgeHost.accessibilityIdentifier(of: view) == "expected.view")
        #expect(SyntheticBadgeHost.accessibilityIdentifier(of: NSObject()) == nil)
    }

    @Test func accessibilityGraphDiagnosticsRedactContentAndTraverseNonViewContainers() {
        let container = NonViewAccessibilityContainer()
        container.dynamicElement.accessibilityIdentifier = "expected.identifier"
        container.dynamicElement.accessibilityLabel = "private label"
        container.dynamicElement.accessibilityValue = "private value"
        container.dynamicElement.accessibilityHint = "private hint"

        let snapshot = accessibilityGraphSnapshot(
            root: container, expectedIdentifiers: ["expected.identifier", "other.identifier"])

        #expect(snapshot.contains("path=root.dynamic[0]"))
        #expect(snapshot.contains("labelPresent=true identifierMatches=[true,false]"))
        #expect(!snapshot.contains("private label"))
        #expect(!snapshot.contains("private value"))
        #expect(!snapshot.contains("private hint"))
    }

    @Test func accessibilityGraphDiagnosticsAreCycleSafeAndBounded() {
        let cycle = NSObject()
        cycle.accessibilityElements = [cycle]
        #expect(accessibilityGraphSnapshot(
            root: cycle, expectedIdentifiers: []).split(separator: "\n").count == 1)
        cycle.accessibilityElements = nil

        let wideRoot = NSObject()
        wideRoot.accessibilityElements = (0..<100).map { _ in NSObject() }
        let wideSnapshot = accessibilityGraphSnapshot(root: wideRoot, expectedIdentifiers: [])
        #expect(wideSnapshot.split(separator: "\n").count == 64)
        #expect(wideSnapshot.count <= 32_768)

        let deepRoot = NSObject()
        var tail = deepRoot
        for _ in 0..<12 {
            let child = NSObject()
            tail.accessibilityElements = [child]
            tail = child
        }
        let deepSnapshot = accessibilityGraphSnapshot(root: deepRoot, expectedIdentifiers: [])
        #expect(deepSnapshot.contains("depth=8"))
        #expect(!deepSnapshot.contains("depth=9"))
    }

    @Test func accessibilityGraphObservationCannotRescueAnInitialMissingIdentifier() {
        let element = UIAccessibilityElement(accessibilityContainer: NSObject())
        let initialBadges = initialBadgeFrames(
            identifiers: ["expected.identifier"], elements: [element])

        element.accessibilityIdentifier = "expected.identifier"

        #expect(initialBadges[0] == nil)
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

    @Test(arguments: [ColorScheme.light, .dark])
    func sidebarSelectionBackgroundIsNeutralGreyOnlyWhenSelected(scheme: ColorScheme) throws {
        #expect(WorkspaceListSidebar.rowSelectionBackground(
            isSelected: false, colorScheme: scheme) == .clear)

        let selected = try rgba(WorkspaceListSidebar.rowSelectionBackground(
            isSelected: true, colorScheme: scheme))
        let sidebar = try rgba(Theme.sidebar(for: scheme))
        let neutralTolerance: CGFloat = 0.05
        let minimumLuminanceGap: CGFloat = 0.05

        #expect(selected.alpha == 1)
        #expect(abs(selected.red - selected.green) < neutralTolerance)
        #expect(abs(selected.blue - selected.green) < neutralTolerance)
        if scheme == .light {
            #expect(sidebar.luminance - selected.luminance > minimumLuminanceGap)
        } else {
            #expect(selected.luminance - sidebar.luminance > minimumLuminanceGap)
        }
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    private func rgba(_ color: Color) throws -> RGBA {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
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

    private static let badgeLabels: [String?] = [
        "Merged pull request #123456789", "100 additional pull requests",
    ]

    private static let badgeIdentifiers = [
        WorkspaceRowView.BadgeIdentifier.pullRequest,
        WorkspaceRowView.BadgeIdentifier.additionalPullRequests,
    ]

    private struct RenderedBadge {
        let identifier: String
        let label: String?
        let frame: CGRect
    }

    private struct RenderedBadges {
        let hostFrame: CGRect
        let badges: [RenderedBadge]
    }

    // Badges are located by their stable accessibility identifier; the spoken
    // label is asserted separately so a copy change cannot masquerade as a
    // missing element.
    private func renderBadges(width: CGFloat) throws -> RenderedBadges {
        let indicator = WorkspaceRowView.PrIndicatorModel(
            pill: .init(status: .merged, number: 123_456_789),
            otherMonitorCount: 100)
        let rootView = WorkspaceRowView.PullRequestBadges(
            indicator: indicator,
            colorScheme: .light,
            colorSchemeContrast: .standard,
            expanded: true)
            .environment(\.dynamicTypeSize, .accessibility3)
        return try SyntheticBadgeHost.render(rootView, width: width, height: 300) { hostView, window in
            let identifiers = Self.badgeIdentifiers
            let elements = SyntheticBadgeHost.accessibilityElements(in: hostView)
            let initialBadges = initialBadgeFrames(identifiers: identifiers, elements: elements)
            if initialBadges.contains(where: { $0 == nil }) {
                let immediate = accessibilityGraphSnapshot(
                    root: window, expectedIdentifiers: identifiers)
                _ = RunLoop.current.run(
                    mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                let observed = accessibilityGraphSnapshot(
                    root: window, expectedIdentifiers: identifiers)
                print("SYNTHETIC PR badge accessibility graph immediate:\n\(immediate)")
                print("SYNTHETIC PR badge accessibility graph after run-loop observation:\n\(observed)")
            }
            let badges = try initialBadges.map { initialBadge in
                try #require(initialBadge)
            }
            let hostFrame = hostView.convert(hostView.bounds, to: nil)
            return RenderedBadges(hostFrame: hostFrame, badges: badges)
        }
    }

    private func initialBadgeFrames(
        identifiers: [String], elements: [NSObject]
    ) -> [RenderedBadge?] {
        identifiers.map { identifier in
            elements.first { SyntheticBadgeHost.accessibilityIdentifier(of: $0) == identifier }.map {
                RenderedBadge(
                    identifier: identifier, label: $0.accessibilityLabel,
                    frame: $0.accessibilityFrame)
            }
        }
    }

    private func accessibilityGraphSnapshot(
        root: NSObject,
        expectedIdentifiers: [String],
        maxNodes: Int = 64,
        maxDepth: Int = 8,
        maxOutputCharacters: Int = 32_768
    ) -> String {
        var visited: Set<ObjectIdentifier> = []
        var lines: [String] = []

        func visit(_ object: NSObject, path: String, depth: Int) {
            guard depth <= maxDepth, visited.count < maxNodes else { return }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }

            let propertyChildren = (object.accessibilityElements ?? [])
                .prefix(maxNodes)
                .compactMap { $0 as? NSObject }
            let elementCount = object.accessibilityElementCount()
            let dynamicChildren: [NSObject]
            if elementCount == NSNotFound || elementCount < 0 {
                dynamicChildren = []
            } else {
                dynamicChildren = (0..<min(elementCount, maxNodes)).compactMap {
                    object.accessibilityElement(at: $0) as? NSObject
                }
            }
            let subviews = (object as? UIView).map {
                Array($0.subviews.prefix(maxNodes))
            } ?? []
            let label = object.accessibilityLabel
            let identifier = SyntheticBadgeHost.accessibilityIdentifier(of: object)
            let identifierMatches = expectedIdentifiers.map { identifier == $0 }
                .map { String($0) }
                .joined(separator: ",")
            let countDescription = elementCount == NSNotFound ? "NSNotFound" : "\(elementCount)"
            let className = String(String(describing: type(of: object)).prefix(80))
            let viewFacts: String
            if let view = object as? UIView {
                viewFacts = "attached=\(view.window != nil) hidden=\(view.isHidden) bounds=\(view.bounds)"
            } else {
                viewFacts = "attached=na hidden=na bounds=na"
            }
            lines.append(
                "depth=\(depth) path=\(path) class=\(className) \(viewFacts) "
                    + "frame=\(object.accessibilityFrame) elementCount=\(countDescription) "
                    + "children=[property:\(propertyChildren.count),dynamic:\(dynamicChildren.count),"
                    + "subviews:\(subviews.count)] labelPresent=\(label != nil) "
                    + "identifierMatches=[\(identifierMatches)]")

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

/// Hosts a SwiftUI view in a synthetic window for the rendered badge tests and
/// for the accessibility-tree probe that gates them.
@MainActor
enum SyntheticBadgeHost {
    static let probeIdentifier = "workspaceRow.syntheticHost.probe"

    static func render<Content: View, Result>(
        _ content: Content, width: CGFloat, height: CGFloat,
        inspect: (_ hostView: UIView, _ window: UIWindow) throws -> Result
    ) throws -> Result {
        try autoreleasepool {
            let rootView = content.frame(width: width, height: height, alignment: .topLeading)
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
            return try inspect(controller.view, window)
        }
    }

    /// Whether a hosted SwiftUI view exposes its accessibility elements at all.
    /// The simulator lane always enables accessibility (scripts/xcodebuild.sh), so
    /// the probe is only consulted on a physical device; a simulator regression
    /// must surface as a failing badge test, not a skip.
    static func publishesAccessibilityTree() -> Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            let probe = Text("probe").accessibilityIdentifier(probeIdentifier)
            let found = try? render(probe, width: 200, height: 100) { hostView, _ in
                accessibilityElements(in: hostView)
                    .contains { accessibilityIdentifier(of: $0) == probeIdentifier }
            }
            let publishes = found ?? false
            if !publishes {
                print(
                    "SYNTHETIC host probe found no accessibility tree on this physical device; "
                        + "skipping rendered badge tests (see intent-hq/ios#322 for the device-side "
                        + "repair and verification that remain open).")
            }
            return publishes
        #endif
    }

    static func accessibilityElements(in view: UIView) -> [NSObject] {
        let elementCount = view.accessibilityElementCount()
        let direct = elementCount == NSNotFound
            ? (view.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            : (0..<elementCount).compactMap {
                view.accessibilityElement(at: $0) as? NSObject
            }
        return (view.isAccessibilityElement ? [view] : direct)
            + view.subviews.flatMap(accessibilityElements(in:))
    }

    /// SwiftUI's accessibility nodes are not `UIView`s, so read the identifier
    /// through `UIAccessibilityIdentification` rather than a view cast.
    static func accessibilityIdentifier(of object: NSObject) -> String? {
        if let identified = object as? UIAccessibilityIdentification {
            return identified.accessibilityIdentifier
        }
        let selector = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard object.responds(to: selector) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }
}
