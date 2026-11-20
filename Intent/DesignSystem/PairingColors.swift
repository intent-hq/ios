import SwiftUI

extension Constants.Pairing {
    private static let darkBackground = Color(sRGBHex: Constants.DesignPalette.darkCanvas)
    private static let darkForeground = Color(sRGBHex: Constants.DesignPalette.paper)
    private static let darkMutedForeground = Color(sRGBHex: Constants.DesignPalette.mutedGrey)
    private static let darkSurface = Color(sRGBHex: Constants.DesignPalette.darkSurface)
    private static let lightBackground = Color(sRGBHex: Constants.DesignPalette.paper)
    private static let lightForeground = Color(sRGBHex: Constants.DesignPalette.ink)
    static let accent = Color(sRGBHex: Constants.DesignPalette.accentLime)
    static let onAccent = Color(sRGBHex: Constants.DesignPalette.ink)

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkForeground : lightForeground
    }

    static func mutedForeground(for _: ColorScheme) -> Color {
        darkMutedForeground
    }

    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSurface : .white
    }
}
