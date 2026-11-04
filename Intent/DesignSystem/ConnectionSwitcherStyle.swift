import SwiftUI

enum ConnectionSwitcherStyle {
    static let inset: CGFloat = 24
    static let trailingInset: CGFloat = 32
    static let headingSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 4
    static let rowInset: CGFloat = 16
    static let rowHeight: CGFloat = 56
    static let iconSize: CGFloat = 24
    static let rowTextSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 20
    static let pageCornerRadius: CGFloat = 44
    static let shadowRadius: CGFloat = 20
    static let shadowOpacity = 0.1
    static let springResponse = 0.35
    static let springDamping = 0.85

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.surface(for: scheme) : Constants.Pairing.background(for: scheme)
    }

    static func selection(for scheme: ColorScheme) -> Color {
        // Exact 8-bit palette channels preserve Surface/Grey700 from Figma 3575:37803 in dark mode.
        scheme == .dark
            ? Color(sRGBHex: Constants.DesignPalette.charcoalGrey)
            : .white
    }
}
