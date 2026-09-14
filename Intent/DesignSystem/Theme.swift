import SwiftUI
import UIKit

enum Theme {
    private static let increasedMutedForegroundOpacity = 0.9
    private static let increasedBorderOpacity = 0.55

    static func background(for scheme: ColorScheme) -> Color {
        resolvedColor(UIColor(resource: .themeBackground), for: scheme)
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        resolvedColor(UIColor(resource: .themeForeground), for: scheme)
    }

    static func card(for scheme: ColorScheme) -> Color {
        resolvedColor(UIColor(resource: .themeCard), for: scheme)
    }

    static func sidebar(for scheme: ColorScheme) -> Color {
        resolvedColor(UIColor(resource: .themeSidebar), for: scheme)
    }

    static func primary(for scheme: ColorScheme) -> Color {
        resolvedColor(UIColor(resource: .themePrimary), for: scheme)
    }

    static func muted(for scheme: ColorScheme) -> Color {
        resolvedColor(UIColor(resource: .themeMuted), for: scheme)
    }

    static func mutedForeground(
        for scheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard
    ) -> Color {
        if contrast == .increased {
            return foreground(for: scheme).opacity(Self.increasedMutedForegroundOpacity)
        }
        return resolvedColor(UIColor(resource: .themeMutedForeground), for: scheme)
    }

    static func border(
        for scheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard
    ) -> Color {
        if contrast == .increased {
            return foreground(for: scheme).opacity(Self.increasedBorderOpacity)
        }
        return resolvedColor(UIColor(resource: .themeBorder), for: scheme)
    }

    static func destructive(for scheme: ColorScheme) -> Color {
        resolvedColor(UIColor(resource: .themeDestructive), for: scheme)
    }

    private static func resolvedColor(_ color: UIColor, for scheme: ColorScheme) -> Color {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let traits = UITraitCollection(userInterfaceStyle: style)
        return Color(uiColor: color.resolvedColor(with: traits))
    }
}
