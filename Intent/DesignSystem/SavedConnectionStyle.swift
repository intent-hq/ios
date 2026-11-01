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
    // swiftlint:disable:next no_magic_numbers
    static let dividerOpacity: Double = 38 / 255
    static let headingTracking: CGFloat = -0.56
    static let nameTracking: CGFloat = -0.32
    static let infoTracking: CGFloat = -0.12

    // Literal 8-bit channels keep the approved Saved palette directly comparable with the design export.
    // swiftlint:disable no_magic_numbers
    private static let lightBackground = Color(.sRGB, red: 240 / 255, green: 240 / 255, blue: 235 / 255)
    private static let lightForeground = Color(.sRGB, red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    private static let lightMutedForeground = Color(.sRGB, red: 140 / 255, green: 140 / 255, blue: 137 / 255)
    private static let lightDivider = Color.black.opacity(dividerOpacity)
    private static let darkConnectedGreen = Color(.sRGB, red: 111 / 255, green: 163 / 255, blue: 86 / 255)
    // Text-safe status variants: small status captions keep at least 4.5:1 on the card surface.
    private static let lightConnectedGreen = Color(.sRGB, red: 69 / 255, green: 117 / 255, blue: 47 / 255)
    private static let lightStatusMuted = Color(.sRGB, red: 107 / 255, green: 107 / 255, blue: 104 / 255)
    private static let darkStatusMuted = Color(.sRGB, red: 163 / 255, green: 163 / 255, blue: 160 / 255)
    // swiftlint:enable no_magic_numbers

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

    /// Text role for the "Connected" status caption and its dot.
    static func connectedForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkConnectedGreen : lightConnectedGreen
    }

    /// Text role for the other status captions; the address keeps `mutedForeground`.
    static func statusMutedForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkStatusMuted : lightStatusMuted
    }
}
