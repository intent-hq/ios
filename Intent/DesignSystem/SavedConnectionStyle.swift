import SwiftUI

extension Constants.Connections {
    // Saved frame 3051:54118. The shared sheet replaces this two-card estimate
    // with measured content; neither the row count nor text height is capped.
    static let initialSheetHeight: CGFloat = 394
    static let headingToCardsSpacing: CGFloat = 56
    static let cardsToPairingSpacing: CGFloat = 24
    static let cardSpacing: CGFloat = 4
    static let cardMinimumHeight: CGFloat = 96
    static let pairingRowMinimumHeight: CGFloat = 56
    static let cardTextSpacing: CGFloat = 12
    static let infoSpacing: CGFloat = 12
    static let connectedSpacing: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let dividerHeight: CGFloat = 12
    // Keep Figma's exported 0x26 alpha as an exact 8-bit fraction, not a rounded percentage.
    private static let dividerAlpha: UInt32 = 0x26
    static let dividerOpacity = Constants.EightBitChannel.fraction(dividerAlpha)
    static let headingTracking: CGFloat = -0.56
    static let nameTracking: CGFloat = -0.32
    static let infoTracking: CGFloat = -0.12

    // Exact 8-bit palette channels keep the approved Saved palette directly comparable with the design export.
    private static let lightBackground = Color(sRGBHex: Constants.DesignPalette.paper)
    private static let lightForeground = Color(sRGBHex: Constants.DesignPalette.ink)
    private static let lightMutedForeground = Color(sRGBHex: Constants.DesignPalette.mutedGrey)
    private static let lightDivider = Color.black.opacity(dividerOpacity)
    private static let connectedGreen = Color(sRGBHex: Constants.DesignPalette.connectedGreen)

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.background(for: scheme) : lightBackground
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.foreground(for: scheme) : lightForeground
    }

    static func mutedForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.mutedForeground(for: scheme) : lightMutedForeground
    }

    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.surface(for: scheme) : .white
    }

    static func sectionForeground(for scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? foreground(for: scheme) : Constants.ManualTokenEntry.labelForeground(for: scheme)
    }

    static func divider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(dividerOpacity) : lightDivider
    }

    static func connectedForeground(for _: ColorScheme) -> Color {
        connectedGreen
    }
}
