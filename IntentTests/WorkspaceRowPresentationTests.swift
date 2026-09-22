@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct WorkspaceRowPresentationTests {
    // Gated, not skipped silently: on the simulator the wrapper guarantees the
    // accessibility tree, so the condition is always true there and a missing
    // badge is a real failure. Only a physical-device run with accessibility off
    // is excluded, by probing the host rather than guessing.
    @Test(
        .enabled(
            Comment(
                rawValue:
                    "SwiftUI publishes its accessibility tree only when accessibility is enabled "
                    + "for the process (scripts/xcodebuild.sh enables it on the simulator; a "
                    + "physical-device unit-test run needs VoiceOver or an XCUITest session)"
            )
        ) {
            await SyntheticBadgeHost.publishesAccessibilityTree()
        }
    )
    func renderedPrBadgesFitThenFallBackInsideSyntheticHost() async throws {
        let fit = try await renderBadges(width: 600)
        let combinedIdealWidth = fit.badges[0].frame.union(fit.badges[1].frame).width
        let largestBadgeWidth = fit.badges.map { $0.frame.width }.max() ?? 0
        let fallbackWidth = ceil(largestBadgeWidth) + 1
        let renderedFrameTolerance: CGFloat = 0.001

        #expect(
            abs(fit.badges[0].frame.midY - fit.badges[1].frame.midY)
                <= renderedFrameTolerance
        )
        #expect(fit.badges[0].frame.maxX < fit.badges[1].frame.minX)
        #expect(combinedIdealWidth <= fit.hostFrame.width)
        #expect(fallbackWidth < combinedIdealWidth)
        #expect(fit.badges.allSatisfy { $0.frame.width <= fallbackWidth })
        #expect(fit.badges.allSatisfy { fit.hostFrame.contains($0.frame) })
        #expect(fit.badges.map { $0.label } == Self.badgeLabels)

        let fallback = try await renderBadges(width: fallbackWidth)

        #expect(fallback.badges[0].frame.minX == fallback.badges[1].frame.minX)
        #expect(fallback.badges[0].frame.maxY < fallback.badges[1].frame.minY)
        #expect(fallback.badges.allSatisfy { fallback.hostFrame.contains($0.frame) })
        #expect(fallback.badges.map { $0.label } == Self.badgeLabels)
        print("SYNTHETIC PR badge fit geometry: \(fit)")
        print("SYNTHETIC PR badge fallback geometry: \(fallback)")
    }

    @Test func badgeIdentifiersAreStableAndDistinct() {
        #expect(WorkspaceRowView.BadgeIdentifier.pullRequest == "workspaceRow.prBadge")
        #expect(
            WorkspaceRowView.BadgeIdentifier.additionalPullRequests
                == "workspaceRow.prBadge.additional"
        )
    }

    @Test func accessibilityTraversalIncludesDynamicContainerElements() {
        let container = DynamicAccessibilityContainer()

        #expect(container.accessibilityElements == nil)
        #expect(
            SyntheticBadgeHost.accessibilityElements(in: container)
                .map(\.accessibilityLabel) == ["Dynamic container element"]
        )
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
            root: container,
            expectedIdentifiers: ["expected.identifier", "other.identifier"]
        )

        #expect(snapshot.contains("path=root.dynamic[0]"))
        #expect(snapshot.contains("labelPresent=true identifierMatches=[true,false]"))
        #expect(!snapshot.contains("private label"))
        #expect(!snapshot.contains("private value"))
        #expect(!snapshot.contains("private hint"))
    }

    @Test func accessibilityGraphDiagnosticsAreCycleSafeAndBounded() {
        let cycle = NSObject()
        cycle.accessibilityElements = [cycle]
        #expect(
            accessibilityGraphSnapshot(
                root: cycle,
                expectedIdentifiers: []
            ).split(separator: "\n").count == 1
        )
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
            identifiers: ["expected.identifier"],
            elements: [element]
        )

        element.accessibilityIdentifier = "expected.identifier"

        #expect(initialBadges[0] == nil)
    }

    @Test func statusSummaryPreservesConcurrentStatusCues() {
        let workspace = makeWorkspace(
            displayStatus: "needs_attention",
            activity: "agent_running",
            attention: "unread"
        )

        #expect(
            WorkspaceStatusIconView.accessibilitySummary(for: workspace)
                == "Needs Attention, Active agent, Unread attention"
        )
    }

    @Test func waitingSummaryAppearsOnlyWhenWaitingCueIsVisible() {
        let waiting = makeWorkspace(displayStatus: "idle", waiting: true)
        let running = makeWorkspace(
            displayStatus: "idle",
            activity: "agent_running",
            waiting: true
        )

        #expect(
            WorkspaceStatusIconView.accessibilitySummary(for: waiting)
                == "Idle, Waiting"
        )
        #expect(
            WorkspaceStatusIconView.accessibilitySummary(for: running)
                == "Idle, Active agent"
        )
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func sidebarSelectionBackgroundIsNeutralGreyOnlyWhenSelected(scheme: ColorScheme) throws {
        #expect(
            WorkspaceListSidebar.rowSelectionBackground(
                isSelected: false,
                colorScheme: scheme
            ) == .clear
        )

        let selected = try rgba(
            WorkspaceListSidebar.rowSelectionBackground(
                isSelected: true,
                colorScheme: scheme
            )
        )
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

    // With a hardware keyboard attached, iPadOS draws the focused sidebar row's
    // selection as an accent-coloured halo once the row background is
    // customised (ios#339), so the sidebar List must keep the default focus
    // effect disabled. Scans the packaged copy of the source (see
    // TestSourceInputs), never the checkout.
    @Test func sidebarListDisablesKeyboardFocusEffect() throws {
        let source = try String(
            contentsOf: TestSourceInputs.url(for: "Intent/Views/Workspaces/WorkspaceListSidebar.swift"),
            encoding: .utf8
        )
        let listStyle = try #require(source.range(of: ".listStyle(.sidebar)"))
        let rowHelper = try #require(source.range(of: "private func sidebarRow("))
        let listModifiers = source[listStyle.upperBound..<rowHelper.lowerBound]

        #expect(listModifiers.contains(".focusEffectDisabled()"))
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

    func makeWorkspace(
        title: String = "Workspace",
        repositoryName: String? = nil,
        displayStatus: String? = nil,
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
            agentSummaryAgents: [],
            pullRequests: pullRequests
        )
    }

    func makeMonitor(number: Int) -> MonitoredPr {
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
}
