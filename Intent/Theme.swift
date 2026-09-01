import SwiftUI

struct Theme {
    static func background(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.background(for: scheme)
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.foreground(for: scheme)
    }

    static func card(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.card(for: scheme)
    }

    static func sidebar(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.sidebar(for: scheme)
    }

    static func primary(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.primary(for: scheme)
    }

    static func muted(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.muted(for: scheme)
    }

    static func mutedForeground(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.mutedForeground(for: scheme)
    }

    static func border(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.border(for: scheme)
    }

    static func destructive(for scheme: ColorScheme) -> Color {
        Constants.Colors.Theme.destructive(for: scheme)
    }
}

