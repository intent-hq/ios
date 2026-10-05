@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct ConversationDesignTests {
    private typealias Palette = Constants.Conversation.Design.Palette

    @Test(arguments: [ColorScheme.light, .dark])
    func primaryContentRemainsReadableAcrossConversationSurfaces(scheme: ColorScheme) throws {
        for surface in surfaces(for: scheme) {
            #expect(try contrastRatio(Palette.foreground(for: scheme), on: surface) >= 4.5)
            #expect(try contrastRatio(Palette.assistantForeground(for: scheme), on: surface) >= 4.5)
        }
        #expect(try contrastRatio(Palette.onAccent, on: Palette.accent) >= 4.5)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func increasedContrastKeepsSupportingContentReadable(scheme: ColorScheme) throws {
        // Tests the composited result, including opacity; merely comparing RGB would miss
        // a regression where the composer placeholder still uses its faint standard alpha.
        let foregrounds: [(ColorScheme, ColorSchemeContrast) -> Color] = [
            Palette.secondaryForeground, Palette.detailForeground, Palette.subtitleForeground,
            Palette.placeholderForeground, Palette.blockerForeground, Palette.blockerBodyForeground
        ]
        for surface in surfaces(for: scheme) {
            for foreground in foregrounds {
                let standard = try contrastRatio(foreground(scheme, .standard), on: surface)
                let increased = try contrastRatio(foreground(scheme, .increased), on: surface)
                #expect(increased >= 4.5)
                #expect(increased > standard)
            }
            #expect(try contrastRatio(Palette.border(for: scheme, contrast: .increased), on: surface) >= 3)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func standardAnswerCardsRenderSelectedFillAndSubtleUnselectedOutline(scheme: ColorScheme) throws {
        // Independent design values: white selection in light mode, neutral raised
        // fill in dark mode, and a 10% outline only on unselected standard cards.
        let shell: [Double] = scheme == .light ? [240, 240, 235] : [39, 39, 39]
        let raised: [Double] = scheme == .light ? [255, 255, 255] : [61, 61, 60]
        let outline = scheme == .light ? 0.0 : 255.0
        for selected in [false, true] {
            let pixels = try standardAnswerCardPixels(scheme: scheme, selected: selected)
            let edge = selected ? raised : shell.map { $0 * 0.9 + outline * 0.1 }
            let interior = selected ? raised : shell
            for channel in 0..<3 {
                #expect(abs(Double(pixels[channel]) - edge[channel]) <= 2)
                #expect(abs(Double(pixels[7 * 4 + channel]) - interior[channel]) <= 2)
            }
            #expect(pixels[3] == 255 && pixels[7 * 4 + 3] == 255)
        }
    }

    private func standardAnswerCardPixels(scheme: ColorScheme, selected: Bool) throws -> [UInt8] {
        // ImageRenderer starts with the standard environment; no device-level
        // contrast override is injected. Increased Contrast remains a separate policy.
        let renderer = ImageRenderer(content: WorkspaceQuestionAnswerCards(
            options: [QuestionOption(label: "Mountains", description: "Fresh air and a quiet cabin.")],
            selectedIndices: selected ? [0] : [],
            isMulti: false
        ) { _ in }
            .frame(width: 320)
            .background(Palette.surface(for: scheme))
            .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        // Sample the straight left edge and blank inset, away from text and corners.
        let strip = try #require(image.cropping(to: CGRect(x: 0, y: image.height / 2, width: 8, height: 1)))
        var pixels = [UInt8](repeating: 0, count: 8 * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: 8,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 8 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(strip, in: CGRect(x: 0, y: 0, width: 8, height: 1))
        }
        return pixels
    }

    private func surfaces(for scheme: ColorScheme) -> [Color] {
        [Palette.background(for: scheme), Palette.surface(for: scheme), Palette.raisedSurface(for: scheme)]
    }

    private func contrastRatio(_ foreground: Color, on background: Color) throws -> CGFloat {
        let front = try components(foreground)
        let back = try components(background)
        let composite = zip(front.rgb, back.rgb).map { $0 * front.alpha + $1 * (1 - front.alpha) }
        let values = [luminance(composite), luminance(back.rgb)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    private func components(_ color: Color) throws -> (rgb: [CGFloat], alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return ([red, green, blue], alpha)
    }

    private func luminance(_ rgb: [CGFloat]) -> CGFloat {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
