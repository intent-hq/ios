@testable import Intent
import SwiftUI
import Testing
import Textual
import UIKit

/// Text roles must reach 4.5:1 against the exact composited surface they are drawn on.
/// Decorative dots and tints are not text and are not held to the text floor here.
@MainActor
struct ColorContrastTests {
    private static let textMinimum: CGFloat = 4.5

    // MARK: - Saved connection status captions (#728)

    @Test(arguments: [ColorScheme.light, .dark])
    func savedConnectionStatusTextIsReadableOnCards(scheme: ColorScheme) throws {
        let style = Constants.Connections.self
        let textRoles = [
            style.connectedForeground(for: scheme),
            style.statusMutedForeground(for: scheme),
            // Increased contrast replaces every status color with the primary foreground.
            style.foreground(for: scheme)
        ]
        for surface in [style.surface(for: scheme), style.background(for: scheme)] {
            for text in textRoles {
                #expect(try contrastRatio(text, on: surface) >= Self.textMinimum)
            }
        }
    }

    // MARK: - Certificate mismatch caption (#728)

    @Test(arguments: [ColorScheme.light, .dark])
    func certificateMismatchTextIsReadableOverItsWarningTint(scheme: ColorScheme) throws {
        let layout = Constants.CertMismatch.self
        let tint = resolved(UIColor.systemOrange, scheme: scheme).opacity(layout.backgroundOpacity)
        let pageSurfaces: [Color] = scheme == .light
            ? [.white, SettingsStyle.lightSurface, Theme.background(for: scheme), Theme.card(for: scheme)]
            : [
                SettingsStyle.charcoal, Constants.Pairing.background(for: scheme),
                Constants.Pairing.surface(for: scheme), Theme.background(for: scheme), Theme.card(for: scheme)
            ]
        for page in pageSurfaces {
            let surface = try composite(tint, over: page)
            for text in [
                layout.warningForeground(for: scheme),
                Theme.foreground(for: scheme),
                Theme.mutedForeground(for: scheme)
            ] {
                #expect(try contrastRatio(text, on: surface) >= Self.textMinimum)
            }
        }
    }

    // MARK: - Markdown code colors (#730)

    @Test(arguments: [ColorScheme.light, .dark])
    func markdownCodeColorsResolveIncreasedContrastVariants(scheme: ColorScheme) throws {
        let markdown = Constants.Colors.Markdown.self
        let pairs: [(Color, Color)] = [
            (markdown.inlineCodeForeground(for: scheme), markdown.inlineCodeForeground(for: scheme, contrast: .increased)),
            (markdown.inlineCodeBackground(for: scheme), markdown.inlineCodeBackground(for: scheme, contrast: .increased)),
            (markdown.codeBlockBackground(for: scheme), markdown.codeBlockBackground(for: scheme, contrast: .increased))
        ]
        for (standard, increased) in pairs {
            #expect(try components(standard) != components(increased))
        }
    }

    @Test
    func markdownTextualColorsCarryIncreasedContrastVariants() {
        let markdown = Constants.Colors.Markdown.self
        func bridged(_ color: (ColorScheme, ColorSchemeContrast) -> Color) -> DynamicColor {
            DynamicColor(
                light: color(.light, .standard),
                dark: color(.dark, .standard),
                highContrastLight: color(.light, .increased),
                highContrastDark: color(.dark, .increased)
            )
        }
        #expect(CompactMarkdownStyle.codeForeground == bridged(markdown.inlineCodeForeground))
        #expect(CompactMarkdownStyle.codeBackground == bridged(markdown.inlineCodeBackground))
        #expect(CompactCodeBlockStyle.background == bridged(markdown.codeBlockBackground))
    }

    @Test(arguments: [ColorScheme.light, .dark], [ColorSchemeContrast.standard, .increased])
    func markdownInlineCodeIsReadableOnTranscriptSurfaces(
        scheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) throws {
        let markdown = Constants.Colors.Markdown.self
        let palette = Constants.Conversation.Design.Palette.self
        for page in [palette.background(for: scheme), palette.surface(for: scheme), Theme.background(for: scheme)] {
            let standardSurface = try composite(markdown.inlineCodeBackground(for: scheme), over: page)
            let standard = try contrastRatio(markdown.inlineCodeForeground(for: scheme), on: standardSurface)
            let surface = try composite(markdown.inlineCodeBackground(for: scheme, contrast: contrast), over: page)
            let ratio = try contrastRatio(markdown.inlineCodeForeground(for: scheme, contrast: contrast), on: surface)
            #expect(ratio >= Self.textMinimum)
            if contrast == .increased { #expect(ratio > standard) }

            let blockSurface = try composite(markdown.codeBlockBackground(for: scheme, contrast: contrast), over: page)
            #expect(try contrastRatio(palette.assistantForeground(for: scheme), on: blockSurface) >= Self.textMinimum)
        }
    }

    // MARK: - Helpers

    private func resolved(_ color: UIColor, scheme: ColorScheme) -> Color {
        Color(uiColor: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)))
    }

    private func composite(_ foreground: Color, over background: Color) throws -> Color {
        let front = try components(foreground)
        let back = try components(background)
        let rgb = zip(front.rgb, back.rgb).map { $0 * front.alpha + $1 * (1 - front.alpha) }
        return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    private func contrastRatio(_ foreground: Color, on background: Color) throws -> CGFloat {
        let back = try components(background)
        let front = try components(composite(foreground, over: background))
        let values = [luminance(front.rgb), luminance(back.rgb)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    private func components(_ color: Color) throws -> RGBA {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return RGBA(rgb: [red, green, blue], alpha: alpha)
    }

    private func luminance(_ rgb: [CGFloat]) -> CGFloat {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private struct RGBA: Equatable {
        let rgb: [CGFloat]
        let alpha: CGFloat
    }
}
