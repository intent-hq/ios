import SwiftUI

extension Constants.Pairing {
    // Connect-only colors from Figma frame 3051:54405; do not retheme other screens.
    // Light mode keeps the app's existing semantic text/background colors.
    // These named palette constants retain the design's exact 8-bit sRGB channels.
    // swiftlint:disable no_magic_numbers
    private static let darkBackground = Color(.sRGB, red: 22 / 255, green: 22 / 255, blue: 22 / 255)
    private static let darkForeground = Color(.sRGB, red: 240 / 255, green: 240 / 255, blue: 235 / 255)
    private static let darkMutedForeground = Color(.sRGB, red: 140 / 255, green: 140 / 255, blue: 137 / 255)
    private static let darkSurface = Color(.sRGB, red: 39 / 255, green: 39 / 255, blue: 39 / 255)
    private static let lightSurface = Color(.sRGB, red: 242 / 255, green: 242 / 255, blue: 240 / 255)
    static let accent = Color(.sRGB, red: 221 / 255, green: 236 / 255, blue: 97 / 255)
    static let onAccent = Color(.sRGB, red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    // swiftlint:enable no_magic_numbers

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : Theme.background(for: scheme)
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkForeground : Theme.foreground(for: scheme)
    }

    static func mutedForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkMutedForeground : Theme.mutedForeground(for: scheme)
    }

    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSurface : lightSurface
    }
}
