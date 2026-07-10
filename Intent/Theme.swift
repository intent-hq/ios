import SwiftUI

struct Theme {
    // MARK: - Light Mode Colors

    private static let lightBackground = Color.white
    private static let lightForeground = Color(white: 0.09)
    private static let lightCard = Color.white
    private static let lightSidebar = Color(red: 0.95, green: 0.95, blue: 0.97)
    private static let lightPrimary = Color(red: 0.0, green: 0.60, blue: 0.42)
    private static let lightMuted = Color(white: 0.91)
    private static let lightMutedForeground = Color(white: 0.28)
    private static let lightBorder = Color(white: 0.85)
    private static let lightDestructive = Color(red: 0.92, green: 0.25, blue: 0.25)

    // MARK: - Dark Mode Colors

    private static let darkBackground = Color(red: 0.11, green: 0.11, blue: 0.14)
    private static let darkForeground = Color(white: 0.97)
    private static let darkCard = Color(red: 0.07, green: 0.07, blue: 0.09)
    private static let darkSidebar = Color(red: 0.04, green: 0.04, blue: 0.06)
    private static let darkPrimary = Color(red: 0.0, green: 0.60, blue: 0.42)
    private static let darkMuted = Color(red: 0.0, green: 0.0, blue: 0.0)
    private static let darkMutedForeground = Color(red: 0.68, green: 0.66, blue: 0.76)
    private static let darkBorder = Color(red: 0.28, green: 0.27, blue: 0.32)
    private static let darkDestructive = Color(red: 0.88, green: 0.22, blue: 0.22)

    // MARK: - Accessors

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkForeground : lightForeground
    }

    static func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkCard : lightCard
    }

    static func sidebar(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSidebar : lightSidebar
    }

    static func primary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkPrimary : lightPrimary
    }

    static func muted(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkMuted : lightMuted
    }

    static func mutedForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkMutedForeground : lightMutedForeground
    }

    static func border(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBorder : lightBorder
    }

    static func destructive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkDestructive : lightDestructive
    }
}

