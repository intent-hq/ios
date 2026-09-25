@testable import Intent
import SwiftUI
import Testing

@MainActor
struct SavedConnectionCardTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func renderedCardUsesSavedPalette(scheme: ColorScheme) throws {
        let card = SavedConnectionCard(name: "Demo Mac", address: "demo.invalid:8080", isCurrentWindow: true)
            .frame(width: 354)
        let colors = try pixelColors(card, scheme: scheme)
        let expected = scheme == .light
            ? [[255, 255, 255], [8, 8, 8], [140, 140, 137], [111, 163, 86], [217, 217, 217]]
            : [[39, 39, 39], [240, 240, 235], [140, 140, 137], [111, 163, 86], [69, 69, 68]]
        for color in expected {
            #expect(pixelCount(color, in: colors) > 20, "Missing rendered Saved color: \(color), \(scheme)")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func savedSheetOverridesPreserveDefaultColors(scheme: ColorScheme, useSavedColors: Bool) throws {
        let sheet = ConnectionSheet(
            initialHeight: 394,
            backgroundColor: useSavedColors ? Constants.Connections.background(for: scheme) : nil,
            closeForeground: useSavedColors ? Constants.Connections.foreground(for: scheme) : nil
        ) { EmptyView() }
            .frame(width: 402, height: 394)
        let colors = try pixelColors(sheet, scheme: scheme)
        let lightBackground = useSavedColors ? [240, 240, 235] : [255, 255, 255]
        let lightClose = useSavedColors ? [8, 8, 8] : [23, 23, 23]
        let background = scheme == .light ? lightBackground : [22, 22, 22]
        let close = scheme == .light ? lightClose : [240, 240, 235]
        #expect(pixelCount(background, in: colors) > 100_000)
        #expect(pixelCount(close, in: colors) > 20)
    }

    @Test func referenceCardsGrowForLongContentRatherThanClipping() throws {
        for current in [false, true] {
            let normal = try render(name: "Example Computer", address: "192.0.2.42:5180", current: current)
            #expect(normal == CGSize(width: 354, height: 96))
            let long = try render(
                name: "A saved connection with a much longer descriptive name that must wrap onto multiple lines",
                address: "host-with-a-long-name.example.invalid:5180, 192.0.2.43:5180",
                current: current
            )
            #expect(long.width == 354)
            #expect(long.height > normal.height)
        }
    }

    private func pixelColors<V: View>(_ view: V, scheme: ColorScheme) throws -> [[Int]] {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).compactMap { index in
            guard bytes[index + 3] == 255 else { return nil }
            return [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
        }
    }

    private func pixelCount(_ color: [Int], in pixels: [[Int]]) -> Int {
        pixels.filter { pixel in zip(pixel, color).allSatisfy { abs($0 - $1) <= 1 } }.count
    }

    private func render(name: String, address: String, current: Bool) throws -> CGSize {
        let renderer = ImageRenderer(content: SavedConnectionCard(name: name, address: address, isCurrentWindow: current)
            .frame(width: 354)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }
}