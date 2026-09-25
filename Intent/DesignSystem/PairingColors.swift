import SwiftUI

extension Constants.Pairing {
    // Connect/Manual colors from full-frame Figma modes: dark 3051:54405, light 3051:54203.
    // Keep these connection-scoped; the app's global Theme is unchanged.
    // These named palette constants retain the design's exact 8-bit sRGB channels.
    // swiftlint:disable no_magic_numbers
    private static let darkBackground = Color(.sRGB, red: 22 / 255, green: 22 / 255, blue: 22 / 255)
    private static let darkForeground = Color(.sRGB, red: 240 / 255, green: 240 / 255, blue: 235 / 255)
    private static let darkMutedForeground = Color(.sRGB, red: 140 / 255, green: 140 / 255, blue: 137 / 255)
    private static let darkSurface = Color(.sRGB, red: 39 / 255, green: 39 / 255, blue: 39 / 255)
    private static let lightBackground = Color(.sRGB, red: 240 / 255, green: 240 / 255, blue: 235 / 255)
    private static let lightForeground = Color(.sRGB, red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    static let accent = Color(.sRGB, red: 221 / 255, green: 236 / 255, blue: 97 / 255)
    static let onAccent = Color(.sRGB, red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    // swiftlint:enable no_magic_numbers

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
