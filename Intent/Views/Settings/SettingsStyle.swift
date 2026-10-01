import SwiftUI

/// The Settings surface deliberately does not change the app-wide theme.
enum SettingsStyle {
    static let contentMargin: CGFloat = 24
    static let sectionSpacing: CGFloat = 24
    static let headingSpacing: CGFloat = 32
    static let sectionHeaderSpacing: CGFloat = 20
    static let appearanceBottomSpacing: CGFloat = 12
    static let headerGap: CGFloat = 48
    static let cardRadius: CGFloat = 20
    static let surfaceRadius: CGFloat = 44
    static let segmentRadius: CGFloat = 16
    static let trackInset: CGFloat = 4
    static let segmentHeight: CGFloat = 48
    static let rowHeight: CGFloat = 56
    static let connectionHeight: CGFloat = 96
    static let iconWidth: CGFloat = 24
    static let rowSpacing: CGFloat = 24
    static let metadataSpacing: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 16
    static let maximumContentWidth: CGFloat = 600
    static let statusDotSize: CGFloat = 8

    private static let surfaceRGB: UInt32 = 0xF0F0EB
    private static let foregroundRGB: UInt32 = 0x080808
    private static let charcoalRGB: UInt32 = 0x1A1A19
    private static let accentRGB: UInt32 = 0xDDEC61
    private static let connectedRGB: UInt32 = 0x6FA356
    private static let mutedRGB: UInt32 = 0x8C8C89
    private static let sectionRGB: UInt32 = 0x525250
    private static let chromeRGB: UInt32 = 0xDADAD5
    private static let byteMask: UInt32 = 255
    private static let redShift = 16
    private static let greenShift = 8

    static let lightSurface = color(surfaceRGB)
    static let lightForeground = color(foregroundRGB)
    static let charcoal = color(charcoalRGB)
    static let accent = color(accentRGB)
    static let connected = color(connectedRGB)
    static let lightMuted = color(mutedRGB)
    static let lightSection = color(sectionRGB)
    static let lightChrome = color(chromeRGB)

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> redShift) & byteMask) / Double(byteMask),
            green: Double((rgb >> greenShift) & byteMask) / Double(byteMask),
            blue: Double(rgb & byteMask) / Double(byteMask)
        )
    }

    static func surface(for scheme: ColorScheme) -> Color {
        Constants.Connections.background(for: scheme)
    }

    static func card(for scheme: ColorScheme) -> Color {
        Constants.Connections.surface(for: scheme)
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        Constants.Connections.foreground(for: scheme)
    }

    static func muted(for scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return foreground(for: scheme) }
        return Constants.Connections.mutedForeground(for: scheme)
    }

    static func sectionForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        Constants.Connections.sectionForeground(for: scheme, contrast: contrast)
    }
}
