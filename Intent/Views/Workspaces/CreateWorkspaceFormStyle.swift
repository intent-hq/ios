import CoreText
import SwiftUI

enum CreateWorkspaceFormStyle {
    static let pagePadding: CGFloat = 24
    static let headingTopPadding: CGFloat = 12
    static let headingSpacing: CGFloat = 41
    static let sectionSpacing: CGFloat = 48
    static let agentSectionSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 8
    static let controlPadding: CGFloat = 20
    static let controlVerticalPadding: CGFloat = 12
    static let controlHeight: CGFloat = 48
    static let cornerRadius: CGFloat = 20
    static let promptHeight: CGFloat = 180
    static let attachmentTarget: CGFloat = 44
    static let headingTracking: CGFloat = -0.56
    static let agentHeadingTracking: CGFloat = 0.24
    static let bodyTracking: CGFloat = -0.32
    static let sourceHeight: CGFloat = 80
    static let fieldLabelWidth: CGFloat = 106
    private static let primaryRed = 0.867
    private static let primaryGreen = 0.925
    private static let primaryBlue = 0.380
    private static let primaryTextWhite = 0.031
    private static let darkCardWhite = 0.153
    private static let darkForegroundRedGreen = 0.941
    private static let darkForegroundBlue = 0.922
    private static let darkSecondaryRedGreen = 0.549
    private static let darkSecondaryBlue = 0.537
    static let primary = Color(red: primaryRed, green: primaryGreen, blue: primaryBlue)
    static let primaryForeground = Color(white: primaryTextWhite)

    static func background(for scheme: ColorScheme) -> Color {
        Constants.Pairing.background(for: scheme)
    }

    static func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: darkCardWhite) : .white
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

/// Shared presentation for repository and branch selection.
enum CreateWorkspaceRepoStyle {
    static let titleSpacing: CGFloat = 56
    static let sectionSpacing: CGFloat = 32
    static let sectionHeaderSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 24
    static let rowTextSpacing: CGFloat = 12
    static let rowMinimumHeight: CGFloat = 80
    static let iconSize: CGFloat = 24
    static let avatarRadius: CGFloat = 8
    static let titleTracking: CGFloat = -0.56
    static let sectionTracking: CGFloat = 0.24
    static let nameTracking: CGFloat = -0.32
    static let fullNameTracking: CGFloat = -0.12
    static let dividerHeight: CGFloat = 1
    static let dividerOpacity = 0.1
    static let checkCropRatio: CGFloat = 0.25
    static let checkCircleInsetRatio: CGFloat = 0.0625
    static let nameCapHeight = capHeight(Constants.Typography.bodySEmphasized)
    static let fullNameCapHeight = capHeight(Constants.Typography.subtextXXS)

    private static func capHeight(_ style: Constants.Typography.Style) -> CGFloat {
        CTFontGetCapHeight(CTFontCreateWithName(style.face.rawValue as CFString, style.size, nil))
    }

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? CreateWorkspaceFormStyle.background(for: scheme) : SettingsStyle.lightSurface
    }

    static func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? CreateWorkspaceFormStyle.card(for: scheme) : .white
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? CreateWorkspaceFormStyle.foreground(for: scheme) : SettingsStyle.lightForeground
    }

    static func secondary(for scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return foreground(for: scheme) }
        return scheme == .dark
            ? CreateWorkspaceFormStyle.secondary(for: scheme, contrast: contrast) : SettingsStyle.lightMuted
    }

    static func sectionForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return foreground(for: scheme) }
        return scheme == .dark
            ? CreateWorkspaceFormStyle.secondary(for: scheme, contrast: contrast) : SettingsStyle.lightSection
    }

    static func divider(for scheme: ColorScheme) -> Color {
        (scheme == .dark ? Color.white : .black).opacity(dividerOpacity)
    }
}
