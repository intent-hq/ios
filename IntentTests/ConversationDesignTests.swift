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
