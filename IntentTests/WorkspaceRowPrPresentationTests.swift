@testable import Intent
import SwiftUI
import Testing
import UIKit

extension WorkspaceRowPresentationTests {
    private enum TextRaster {
        static let byteMaximum: CGFloat = 255
        static let scale: CGFloat = 3
        static let channels = 4
        static let bitsPerComponent = 8
    }

    @Test(
        .enabled("Requires the hosted SwiftUI accessibility tree") {
            await SyntheticBadgeHost.publishesAccessibilityTree()
        },
        arguments: ["fractional", "whole", "invalid"]
    )
    func renderedRowTimestampsPreserveRelativeTimeAndInvalidFallback(format: String) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = format == "fractional"
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        // Stay halfway between hour boundaries so rendering cannot change the label.
        let timestamp = format == "invalid"
            ? "not-a-timestamp" : formatter.string(from: Date(timeIntervalSinceNow: -9000))
        let expected = format == "invalid" ? "not-a-timestamp" : "2h"
        let agent = try #require(AgentSession.parseAgent([
            "id": "row-timestamp-agent", "name": "Agent", "lastActivity": timestamp
        ]))
        let rows = VStack {
            WorkspaceRowView(workspace: makeWorkspace(lastActivity: timestamp), colorScheme: .light)
            AgentRowView(agent: agent, colorScheme: .light)
        }
        try await SyntheticBadgeHost.render(rows, width: 600, height: 240) { hostView, _ in
            let labels = SyntheticBadgeHost.accessibilityElements(in: hostView).compactMap(\.accessibilityLabel)
            #expect(labels.contains("Updated \(expected)"))
            #expect(labels.contains(expected))
        }
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

    @Test(arguments: [ColorScheme.light, .dark])
    func renderedSecondaryTextUsesGrey500(scheme: ColorScheme) throws {
        for status in ["active", "archived"] {
            let workspace = makeWorkspace(
                repositoryName: "repository-subtitle",
                status: status,
                lastActivity: "timestamp",
                prStatus: "Open",
                prNumber: 49
            )
            let content = VStack {
                WorkspaceRowView(workspace: workspace, colorScheme: scheme, statusIconHidden: true)
                WorkspaceRowView.PullRequestBadges(
                    indicator: .init(pill: nil, otherMonitorCount: 12),
                    colorScheme: scheme,
                    colorSchemeContrast: .standard,
                    expanded: false
                )
            }
            .frame(width: 600)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
            let pixels = try secondaryTextPixels(content)
            // Independent Figma Grey 500 reference, rather than the palette under test.
            let expected = [140, 140, 137, 255]
            #expect(pixelCount(expected, in: pixels) > 20, "Missing secondary text color: \(status), \(scheme)")
            let oldMuted = try premultipliedChannels(Theme.mutedForeground(for: scheme))
            #expect(pixelCount(oldMuted, in: pixels) == 0, "A metadata label still uses the old muted color")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func renderedSecondaryTextPreservesIncreasedContrast(scheme: ColorScheme) throws {
        let badges = WorkspaceRowView.PullRequestBadges(
            indicator: .init(pill: .init(status: .open, number: 49), otherMonitorCount: 12),
            colorScheme: scheme,
            colorSchemeContrast: .increased,
            expanded: false
        )
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, .large)
        let pixels = try secondaryTextPixels(badges)
        let expected = try premultipliedChannels(Theme.foreground(for: scheme).opacity(0.9))
        #expect(pixelCount(expected, in: pixels) > 20)
    }

    private func premultipliedChannels(_ color: Color) throws -> [Int] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red * alpha, green * alpha, blue * alpha, alpha].map { Int(($0 * TextRaster.byteMaximum).rounded()) }
    }

    private func secondaryTextPixels(_ content: some View) throws -> [UInt8] {
        let renderer = ImageRenderer(content: content)
        renderer.scale = TextRaster.scale
        let image = try #require(renderer.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * TextRaster.channels)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: TextRaster.bitsPerComponent,
                bytesPerRow: image.width * TextRaster.channels,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func pixelCount(_ color: [Int], in pixels: [UInt8]) -> Int {
        stride(from: 0, to: pixels.count, by: TextRaster.channels).filter { index in
            (0..<TextRaster.channels).allSatisfy { abs(Int(pixels[index + $0]) - color[$0]) <= 1 }
        }.count
    }
}
