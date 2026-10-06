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
        },
        arguments: [WorkspacePrPill.Status.open, .draft, .merged, .closed],
        [ColorScheme.light, .dark]
    )
    func renderedPrBadgesFitThenFallBackInsideSyntheticHost(
        status: WorkspacePrPill.Status,
        colorScheme: ColorScheme
    ) async throws {
        let labels = Self.badgeLabels(for: status)
        let normal = try await renderBadges(width: 600, status: status, colorScheme: colorScheme, dynamicTypeSize: .large)
        #expect(normal.badges.map { $0.label } == labels)
        #expect(normal.badges.allSatisfy { normal.hostFrame.contains($0.frame) })
        let fit = try await renderBadges(width: 600, status: status, colorScheme: colorScheme)
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
        #expect(fit.badges.map { $0.label } == labels)

        let fallback = try await renderBadges(width: fallbackWidth, status: status, colorScheme: colorScheme)

        #expect(fallback.badges[0].frame.minX == fallback.badges[1].frame.minX)
        #expect(fallback.badges[0].frame.maxY < fallback.badges[1].frame.minY)
        #expect(fallback.badges.allSatisfy { fallback.hostFrame.contains($0.frame) })
        #expect(fallback.badges.map { $0.label } == labels)
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

    @Test func waitingSummaryPreservesRunningPrecedence() {
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

    @Test(arguments: [
        "failed", "blocked", "needs_attention", "idle", "not_started", "in_progress",
        "complete", "pr_ready", "pr_open", "pr_queued", "pr_merged", "future_status"
    ])
    func renderedStatusUsesPlainDotOrNotStartedRing(wireStatus: String) throws {
        let workspace = makeWorkspace(displayStatus: wireStatus)
        let status = resolveDisplayStatus(for: workspace)
        let color = try expectedStatusColor(status)
        for scheme in [ColorScheme.light, .dark] {
            let pixels = try renderStatus(workspace, scheme: scheme)
            try expectStatusSilhouette(pixels, color: color, scheme: scheme, ring: status == .notStarted)
        }
    }

    @Test func activityAttentionAndWaitingDoNotAddVisibleStatusCues() throws {
        let plain = try renderStatus(makeWorkspace(displayStatus: "idle"))
        for workspace in [
            makeWorkspace(displayStatus: "idle", activity: "agent_running"),
            makeWorkspace(displayStatus: "idle", attention: "unread"),
            makeWorkspace(displayStatus: "idle", waiting: true),
            makeWorkspace(displayStatus: "idle", activity: "agent_running", attention: "unread", waiting: true)
        ] {
            #expect(try renderStatus(workspace) == plain)
        }
    }
}

extension WorkspaceRowPresentationTests {
    private func expectedStatusColor(_ status: WorkspaceDisplayStatus) throws -> Color {
        // Figma Status Colors (3448:29525): independent of the assets under test.
        // swiftlint:disable no_magic_numbers
        let figmaRGB: [WorkspaceDisplayStatus: RGBA] = [
            .failed: RGBA(red: 232, green: 127, blue: 57, alpha: 1),
            .blocked: RGBA(red: 191, green: 99, blue: 38, alpha: 1),
            .needsAttention: RGBA(red: 250, green: 167, blue: 85, alpha: 1),
            .idle: RGBA(red: 186, green: 186, blue: 183, alpha: 1),
            .notStarted: RGBA(red: 140, green: 140, blue: 137, alpha: 1),
            .inProgress: RGBA(red: 221, green: 236, blue: 97, alpha: 1),
            .complete: RGBA(red: 111, green: 163, blue: 86, alpha: 1),
            .prReady: RGBA(red: 130, green: 205, blue: 98, alpha: 1),
            .prOpen: RGBA(red: 192, green: 168, blue: 237, alpha: 1),
            .prQueued: RGBA(red: 194, green: 212, blue: 242, alpha: 1),
            .prMerged: RGBA(red: 194, green: 212, blue: 242, alpha: 1),
            .unknown: RGBA(red: 207, green: 207, blue: 205, alpha: 1)
        ]
        // swiftlint:enable no_magic_numbers
        let rgb = try #require(figmaRGB[status])
        return Color(
            .sRGB,
            red: Double(rgb.red) / StatusRaster.byteMaximum,
            green: Double(rgb.green) / StatusRaster.byteMaximum,
            blue: Double(rgb.blue) / StatusRaster.byteMaximum,
            opacity: Double(rgb.alpha)
        )
    }

    private enum StatusRaster {
        static let padding: CGFloat = 4
        static let scale: CGFloat = 3
        static let side = 72
        static let channels = 4
        static let alphaOffset = 3
        static let bitsPerComponent = 8
        static let byteMaximum = 255.0
        static let center = 36.0
        static let outsideRadius = 25.0
        static let insideRadius = 23.0
        static let holeRadius = 17.0
        static let borderRadius = 19.0
        static let firstPixel = 12
        static let lastPixel = 59
    }

    private func renderStatus(_ workspace: Workspace, scheme: ColorScheme = .dark) throws -> [UInt8] {
        let side = StatusRaster.side
        let renderer = ImageRenderer(content: WorkspaceStatusIconView(workspace: workspace, colorScheme: scheme)
            .padding(StatusRaster.padding)
            .environment(\.colorScheme, scheme))
        renderer.scale = StatusRaster.scale
        let image = try #require(renderer.cgImage)
        // 16 pt icon + 4 pt padding on each side, rendered at 3×.
        try #require(image.width == side && image.height == side)
        var pixels = [UInt8](repeating: 0, count: side * side * StatusRaster.channels)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: StatusRaster.bitsPerComponent,
                bytesPerRow: side * StatusRaster.channels,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    private func expectStatusSilhouette(_ pixels: [UInt8], color: Color, scheme: ColorScheme, ring: Bool) throws {
        let side = StatusRaster.side
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let expected = try rgba(Color(uiColor: UIColor(color).resolvedColor(with: traits)))
        let channels = [
            expected.red * expected.alpha, expected.green * expected.alpha,
            expected.blue * expected.alpha, expected.alpha
        ].map { Double($0) * StatusRaster.byteMaximum }
        // A 48 px circle has radius 24; a 2 pt border leaves an 18 px inner radius.
        // Leave a one-pixel tolerance at curved edges for antialiasing.
        #expect((0..<side * side).allSatisfy { index in
            let radius = hypot(
                Double(index % side) + 0.5 - StatusRaster.center,
                Double(index / side) + 0.5 - StatusRaster.center
            )
            if radius >= StatusRaster.outsideRadius || (ring && radius <= StatusRaster.holeRadius) {
                return pixels[index * StatusRaster.channels + StatusRaster.alphaOffset] == 0
            }
            if radius <= StatusRaster.insideRadius, !ring || radius >= StatusRaster.borderRadius {
                return (0..<StatusRaster.channels).allSatisfy { channel in
                    abs(Double(pixels[index * StatusRaster.channels + channel]) - channels[channel]) <= 2
                }
            }
            return true
        })
        let visible = (0..<side * side).filter { index in
            Double(pixels[index * StatusRaster.channels + StatusRaster.alphaOffset]) > channels[StatusRaster.alphaOffset] / 2
        }
        #expect(visible.map { $0 % side }.min() == StatusRaster.firstPixel)
        #expect(visible.map { $0 % side }.max() == StatusRaster.lastPixel)
        #expect(visible.map { $0 / side }.min() == StatusRaster.firstPixel)
        #expect(visible.map { $0 / side }.max() == StatusRaster.lastPixel)
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

    // The custom listRowBackground from ios#339 replaces the system row
    // background that draws the visionOS gaze highlight, so the shared row
    // helper must reapply the hover effect under a visionOS-only guard, shaped
    // to the selection background's corner radius. Scans the packaged copy of
    // the source (see TestSourceInputs), never the checkout.
    @Test func sidebarRowRestoresGazeHoverEffectOnVisionOS() throws {
        let source = try String(
            contentsOf: TestSourceInputs.url(for: "Intent/Views/Workspaces/WorkspaceListSidebar.swift"),
            encoding: .utf8
        )
        let rowHelper = try #require(source.range(of: "private func sidebarRow("))
        let selectionHelper = try #require(source.range(of: "static func rowSelectionBackground("))
        let rowModifiers = source[rowHelper.upperBound..<selectionHelper.lowerBound]
        let guardStart = try #require(rowModifiers.range(of: "#if os(" + "visionOS)"))
        let guardEnd = try #require(
            rowModifiers.range(of: "#endif", range: guardStart.upperBound..<rowModifiers.endIndex)
        )
        let visionOnly = rowModifiers[guardStart.upperBound..<guardEnd.lowerBound]
        let outsideGuard = rowModifiers.replacingCharacters(
            in: guardStart.lowerBound..<guardEnd.upperBound,
            with: ""
        )

        #expect(visionOnly.contains(".hoverEffect("))
        #expect(visionOnly.contains(".contentShape("))
        #expect(visionOnly.contains(".hoverEffect,"))
        #expect(visionOnly.contains("Constants.WorkspaceList.sidebarSelectionCornerRadius"))
        #expect(!outsideGuard.contains(".hoverEffect("))
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        var luminance: CGFloat {
            let redWeight: CGFloat = 0.2126
            let greenWeight: CGFloat = 0.7152
            let blueWeight: CGFloat = 0.0722
            return redWeight * red + greenWeight * green + blueWeight * blue
        }
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
        status: String? = nil,
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
            status: status,
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
