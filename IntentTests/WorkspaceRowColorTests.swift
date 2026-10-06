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
