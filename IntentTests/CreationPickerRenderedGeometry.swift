import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

/// Test-only observation of the painted workspace cards, not their accessibility rectangles.
@MainActor
struct CreationPickerRenderedGeometry {
    enum ObservationError: Error, Equatable {
        case missingOrAmbiguousRegion
        case sharedRegion
        case clippedAtCaptureEdge
    }

    let image: UIImage
    let regions: [CGRect]
    let bounds: CGRect

    private static let channelCount = 4
    private static let colorChannelCount = 3
    private static let bitsPerChannel = 8
    private static let channelMaximum = 255
    private static let colorTolerance = 2
    private static let minimumPaintedArea = 32

    init(window: UIWindow) throws {
        bounds = window.bounds
        let hostView = try #require(window.rootViewController?.view)
        try #require(hostView.bounds == bounds && window.convert(hostView.bounds, from: hostView) == bounds)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Image pixels and window-local points have the same coordinates.
        format.preferredRange = .standard
        var drawn = false
        image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            drawn = hostView.drawHierarchy(in: hostView.bounds, afterScreenUpdates: true)
        }
        try #require(drawn, "The hosted picker image could not be captured")
        let cgImage = try #require(image.cgImage)
        regions = try Self.cardRegions(in: cgImage)
    }

    func frames(associatedWith accessibilityFrames: [CGRect]) throws -> [CGRect] {
        var selected: [Int] = []
        for frame in accessibilityFrames {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let matches = regions.indices.filter { regions[$0].contains(center) }
            guard matches.count == 1, let index = matches.first else {
                throw ObservationError.missingOrAmbiguousRegion
            }
            guard !selected.contains(index) else { throw ObservationError.sharedRegion }
            let region = regions[index]
            // A clipped bitmap cannot reveal the missing portion. Fail closed instead of
            // accepting its intersection with the canvas as a contained, complete control.
            guard region.minX > bounds.minX, region.minY > bounds.minY,
                  region.maxX < bounds.maxX, region.maxY < bounds.maxY else {
                throw ObservationError.clippedAtCaptureEdge
            }
            selected.append(index)
        }
        return selected.map { regions[$0] }
    }

    func record(named name: String) throws {
        Attachment.record(try #require(image.pngData()), named: "\(name).png")
        Attachment.record(String(describing: regions), named: "\(name)-regions.txt")
    }

    private static func cardRegions(in image: CGImage) throws -> [CGRect] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * channelCount)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: bitsPerChannel,
                bytesPerRow: image.width * channelCount,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let color = UIColor(CreateWorkspaceFormStyle.card(for: .light)).cgColor
        let converted = try #require(color.converted(to: space, intent: .defaultIntent, options: nil))
        let components = try #require(converted.components)
        let target = components.prefix(colorChannelCount).map { Int(($0 * CGFloat(channelMaximum)).rounded()) }
        try #require(target.count == colorChannelCount)
        var mask = stride(from: 0, to: bytes.count, by: channelCount).map { offset in
            bytes[offset + colorChannelCount] == channelMaximum && (0..<colorChannelCount).allSatisfy { channel in
                abs(Int(bytes[offset + channel]) - target[channel]) <= colorTolerance
            }
        }
        var regions: [CGRect] = []
        for seed in mask.indices where mask[seed] {
            let region = connectedRegion(seed: seed, mask: &mask, width: image.width)
            // Tiny anti-aliased glyph islands cannot be a readable control. Do not filter
            // dimensions: a 120x1 clipping strip must still reach the geometry assertions.
            if region.count >= minimumPaintedArea { regions.append(region.bounds) }
        }
        return regions
    }

    private static func connectedRegion(
        seed: Int, mask: inout [Bool], width: Int
    ) -> (bounds: CGRect, count: Int) {
        var pending = [seed]
        mask[seed] = false
        var cursor = 0
        var minX = seed % width
        var maxX = minX
        var minY = seed / width
        var maxY = minY
        while cursor < pending.count {
            let pixel = pending[cursor]
            cursor += 1
            let column = pixel % width
            let row = pixel / width
            minX = min(minX, column)
            maxX = max(maxX, column)
            minY = min(minY, row)
            maxY = max(maxY, row)
            var neighbors: [Int] = []
            if column > 0 { neighbors.append(pixel - 1) }
            if column + 1 < width { neighbors.append(pixel + 1) }
            if pixel >= width { neighbors.append(pixel - width) }
            if pixel + width < mask.count { neighbors.append(pixel + width) }
            for neighbor in neighbors where mask[neighbor] {
                mask[neighbor] = false
                pending.append(neighbor)
            }
        }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), pending.count)
    }
}
