import SwiftUI

/// Scoped to the final workspace form; other creation flows keep their theme.
enum CreateWorkspaceFormStyle {
    static let pagePadding: CGFloat = 24
    static let headingSpacing: CGFloat = 32
    static let sectionSpacing: CGFloat = 48
    static let rowSpacing: CGFloat = 8
    static let controlPadding: CGFloat = 20
    static let controlVerticalPadding: CGFloat = 12
    static let controlHeight: CGFloat = 48
    static let cornerRadius: CGFloat = 20
    static let promptHeight: CGFloat = 180
    static let sourceHeight: CGFloat = 80
    static let fieldLabelWidth: CGFloat = 106
    private static let primaryRed = 0.867
    private static let primaryGreen = 0.925
    private static let primaryBlue = 0.380
    private static let primaryTextWhite = 0.031
    private static let darkBackgroundWhite = 0.086
    private static let darkCardWhite = 0.153
    private static let darkForegroundRedGreen = 0.941
    private static let darkForegroundBlue = 0.922
    private static let darkSecondaryRedGreen = 0.549
    private static let darkSecondaryBlue = 0.537
    static let primary = Color(red: primaryRed, green: primaryGreen, blue: primaryBlue)
    static let primaryForeground = Color(white: primaryTextWhite)

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: darkBackgroundWhite) : Theme.background(for: scheme)
    }

    static func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: darkCardWhite) : Theme.muted(for: scheme)
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: darkForegroundRedGreen, green: darkForegroundRedGreen, blue: darkForegroundBlue)
            : Theme.foreground(for: scheme)
    }

    static func secondary(for scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if scheme == .dark, contrast == .standard {
            return Color(red: darkSecondaryRedGreen, green: darkSecondaryRedGreen, blue: darkSecondaryBlue)
        }
        return Theme.mutedForeground(for: scheme, contrast: contrast)
    }
}
