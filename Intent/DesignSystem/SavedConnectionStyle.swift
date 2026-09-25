import SwiftUI

extension Constants.Connections {
    // Saved frame 3051:54118. The shared sheet replaces this two-card estimate
    // with measured content; neither the row count nor text height is capped.
    static let initialSheetHeight: CGFloat = 394
    static let headingToCardsSpacing: CGFloat = 56
    static let cardSpacing: CGFloat = 4
    static let cardMinimumHeight: CGFloat = 96
    static let pairingRowMinimumHeight: CGFloat = 56
    static let cardTextSpacing: CGFloat = 12
    static let infoSpacing: CGFloat = 12
    static let connectedSpacing: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let dividerHeight: CGFloat = 12
    // Figma Outline/15% Black exports alpha 0x26 in both appearance modes.
    // swiftlint:disable:next no_magic_numbers
    static let dividerOpacity: Double = 38 / 255
    static let headingTracking: CGFloat = -0.56
    static let nameTracking: CGFloat = -0.32
    static let infoTracking: CGFloat = -0.12

    // Preserve the approved exact Saved light palette independently of other destinations.
    // swiftlint:disable no_magic_numbers
    private static let lightBackground = Color(.sRGB, red: 240 / 255, green: 240 / 255, blue: 235 / 255)
    private static let lightForeground = Color(.sRGB, red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    private static let lightMutedForeground = Color(.sRGB, red: 140 / 255, green: 140 / 255, blue: 137 / 255)
    private static let lightDivider = Color.black.opacity(38 / 255)
    private static let connectedGreen = Color(.sRGB, red: 111 / 255, green: 163 / 255, blue: 86 / 255)
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

    static func divider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(dividerOpacity) : lightDivider
    }

    static func connectedForeground(for _: ColorScheme) -> Color {
        connectedGreen
    }
}
