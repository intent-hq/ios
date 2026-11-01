@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct PairingDesignTests {
    @Test(arguments: [
        (["ConnectQR", "ConnectManual", "ConnectSaved"], 24),
        (["ConversationChevronRight", "ConversationChevronUp"], 20)
    ])
    func exportedGlyphsLoadAsDistinctNonemptyTemplateImages(names: [String], side: Int) throws {
        var representations = Set<Data>()
        for name in names {
            let image = try #require(UIImage(named: name))
            #expect(image.size == CGSize(width: CGFloat(side), height: CGFloat(side)))
            #expect(image.renderingMode == .alwaysTemplate)
            let bitmap = try #require(image.cgImage)
            let width = bitmap.width
            let height = bitmap.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let opaquePixels = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
            #expect(opaquePixels > 0, "The exported glyph must not be blank")
            #expect(opaquePixels < width * height, "The glyph must retain a transparent background")
            representations.insert(try #require(image.pngData()))
        }
        #expect(representations.count == names.count, "The exported actions must not accidentally share one glyph")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func paletteMatchesConnectDesign(scheme: ColorScheme) {
        // Full-frame Figma modes: light 3051:54203, dark 3051:54405.
        let expected: [(Color, [CGFloat])] = [
            (Constants.Pairing.background(for: scheme), scheme == .light ? [240, 240, 235] : [22, 22, 22]),
            (Constants.Pairing.foreground(for: scheme), scheme == .light ? [8, 8, 8] : [240, 240, 235]),
            (Constants.Pairing.mutedForeground(for: scheme), [140, 140, 137]),
            (Constants.Pairing.surface(for: scheme), scheme == .light ? [255, 255, 255] : [39, 39, 39]),
            (Constants.Pairing.accent, [221, 236, 97]),
            (Constants.Pairing.onAccent, [8, 8, 8])
        ]
        for (color, channels) in expected {
            for (actual, expectedChannel) in zip(rgb(color), channels) {
                #expect(abs(actual * 255 - expectedChannel) < 0.01)
            }
        }
    }

    @Test func lightPrimaryTextAndGlyphsRemainReadableOnBothSurfaces() {
        // Exact Figma secondary text is below 4.5:1; palette parity is not an accessibility approval.
        for background in [Constants.Pairing.background(for: .light), Constants.Pairing.surface(for: .light)] {
            #expect(contrast(Constants.Pairing.foreground(for: .light), background) >= 4.5)
        }
        #expect(contrast(Constants.Pairing.onAccent, Constants.Pairing.accent) >= 4.5)
    }

    @Test func rowsMatchDesignHeightsAndGrowRatherThanCapText() throws {
        for prominent in [false, true] {
            for width: CGFloat in [327, 354, 480] {
                let normal = try renderedRowSize(width: width, prominent: prominent, category: .large)
                #expect(normal.width == width)
                #expect(normal.height == (prominent ? 112 : 64))
                let accessible = try renderedRowSize(width: width, prominent: prominent, category: .accessibility5)
                #expect(accessible.width == width)
                #expect(accessible.height > normal.height)
            }
        }
    }

    @Test func optionRowsRespondToBoldText() throws {
        for prominent in [false, true] {
            let regular = try renderedRowImage(width: 354, prominent: prominent, category: .large)
            let bold = try renderedRowImage(width: 354, prominent: prominent, category: .large, legibilityWeight: .bold)
            #expect(try #require(UIImage(cgImage: regular).pngData()) != #require(UIImage(cgImage: bold).pngData()))
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func qrRowUsesFigmaCircularCornerContour(scheme: ColorScheme) throws {
        // Figma 3051:54210/3051:54412: the first point row is ~34.5pt inward;
        // SwiftUI's default continuous curve measured 41.5pt (ios#506).
        let image = try renderedRowImage(width: 354, prominent: true, category: .large, colorScheme: scheme)
        let alpha = try alphaChannel(image)
        let radius = Constants.Pairing.optionCornerRadius
        let width = image.width
        let height = image.height
        for row in 0..<Int(radius) {
            let offset = radius - CGFloat(row) - 0.5
            let expected = radius - (radius * radius - offset * offset).squareRoot()
            for y in [row, height - 1 - row] {
                let opaque = (0..<width).filter { alpha[y * width + $0] >= 128 }
                let leading = CGFloat(try #require(opaque.first))
                let trailing = CGFloat(width - 1 - (try #require(opaque.last)))
                #expect(abs(leading + 0.5 - expected) <= 1, "row \(y) leading inset \(leading)")
                #expect(abs(trailing + 0.5 - expected) <= 1, "row \(y) trailing inset \(trailing)")
            }
        }
    }

    private func renderedRowSize(width: CGFloat, prominent: Bool, category: DynamicTypeSize) throws -> CGSize {
        let image = try renderedRowImage(width: width, prominent: prominent, category: category)
        return CGSize(width: image.width, height: image.height)
    }

    private func renderedRowImage(
        width: CGFloat,
        prominent: Bool,
        category: DynamicTypeSize,
        legibilityWeight: LegibilityWeight = .regular,
        colorScheme: ColorScheme = .dark
    ) throws -> CGImage {
        let row = PairingOptionButton(
            icon: prominent ? .connectQR : .connectManual,
            title: prominent ? "Scan QR Code" : "Manual Connection",
            subtitle: prominent ? "Fastest way to connect" : "Enter IP, port, and token",
            isProminent: prominent,
            colorScheme: colorScheme
        ) {}
        let renderer = ImageRenderer(content: row.frame(width: width)
            .environment(\.dynamicTypeSize, category)
            .environment(\.legibilityWeight, legibilityWeight))
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func alphaChannel(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    private func rgb(_ color: Color) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil)
        return [red, green, blue]
    }

    private func contrast(_ foreground: Color, _ background: Color) -> CGFloat {
        func luminance(_ color: Color) -> CGFloat {
            let linear = rgb(color).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let values = [luminance(foreground), luminance(background)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
}
