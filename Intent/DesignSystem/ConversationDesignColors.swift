import SwiftUI

extension Constants.Conversation.Design {
    /// Conversation-only palette. Reuses the already-shipping neutral/yellow Figma colors
    /// from Pairing and Theme's white surface without changing either existing palette.
    enum Palette {
        private static let secondaryOpacity: Double = 0.6
        private static let subtitleOpacity: Double = 0.5
        private static let placeholderOpacity: Double = 0.4
        private static let increasedForegroundOpacity: Double = 0.9
        private static let increasedBorderOpacity: Double = 0.55

        // Exact sRGB values from full-frame modes 3020:36994 / 3016:35726,
        // answer cards 3223:18416 / 3223:19376 and blockers 3198:12684 / 3198:11702.
        // Exact 8-bit palette channels and alpha retain direct comparison with those design exports.
        private static let lightSecondary = Color(sRGBHex: Constants.DesignPalette.darkGrey)
        private static let darkRaisedSurface = Color(sRGBHex: Constants.DesignPalette.charcoalGrey)
        private static let blocker = Color(sRGBHex: Constants.DesignPalette.blockerOrange)
        private static let blockerBody = Color(sRGBHex: Constants.DesignPalette.blockerBody)
        private static let borderAlpha: UInt32 = 0x1A
        private static let borderOpacity = Constants.EightBitChannel.fraction(borderAlpha)

        static let accent = Constants.Pairing.accent
        static let onAccent = Constants.Pairing.onAccent

        static func background(for scheme: ColorScheme) -> Color {
            scheme == .dark ? Constants.Pairing.background(for: scheme) : Theme.background(for: scheme)
        }

        /// User bubbles, composer, monitoring strip and question shell.
        static func surface(for scheme: ColorScheme) -> Color {
            scheme == .dark ? Constants.Pairing.surface(for: scheme) : Constants.Pairing.background(for: scheme)
        }

        /// Selected answers and secondary question actions sit above the shell.
        static func raisedSurface(for scheme: ColorScheme) -> Color {
            scheme == .dark ? darkRaisedSurface : Theme.card(for: scheme)
        }

        static func foreground(for scheme: ColorScheme) -> Color {
            Constants.Pairing.foreground(for: scheme)
        }

        static func assistantForeground(for scheme: ColorScheme) -> Color {
            scheme == .dark ? .white : foreground(for: scheme)
        }

        static func secondaryForeground(
            for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard
        ) -> Color {
            if contrast == .increased {
                return foreground(for: scheme).opacity(Self.increasedForegroundOpacity)
            }
            return scheme == .dark ? Constants.Pairing.mutedForeground(for: scheme) : Self.lightSecondary
        }

        static func detailForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
            foreground(for: scheme).opacity(contrast == .increased ? Self.increasedForegroundOpacity : Self.secondaryOpacity)
        }

        static func subtitleForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
            foreground(for: scheme).opacity(contrast == .increased ? Self.increasedForegroundOpacity : Self.subtitleOpacity)
        }

        static func placeholderForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
            foreground(for: scheme).opacity(contrast == .increased ? Self.increasedForegroundOpacity : Self.placeholderOpacity)
        }

        static func border(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
            if contrast == .increased {
                return foreground(for: scheme).opacity(Self.increasedBorderOpacity)
            }
            return (scheme == .dark ? Color.white : .black).opacity(Self.borderOpacity)
        }

        static func blockerForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
            contrast == .increased ? foreground(for: scheme) : Self.blocker
        }

        static func blockerBodyForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
            contrast == .increased ? secondaryForeground(for: scheme, contrast: contrast) : Self.blockerBody
        }
    }
}
