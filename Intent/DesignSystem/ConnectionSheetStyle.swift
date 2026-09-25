import SwiftUI

extension Constants {
    /// Manual frames 2989:19990 / 2989:20026; reusable destination-sheet geometry.
    /// Palette intentionally reuses Connect's matching colors without changing them.
    enum ConnectionSheet {
        static let inset: CGFloat = 24
        static let glyphSize: CGFloat = 24
        static let closeSize: CGFloat = 48
        static let cornerRadius: CGFloat = 44
        static let fieldCornerRadius: CGFloat = 20
        static let headerGap: CGFloat = 36
        static let bottomSpacing: CGFloat = 48
        static let minimumBottomPadding: CGFloat = 14
        static let fieldHeight: CGFloat = 64
        static let fieldVerticalPadding: CGFloat = 16
        static let minimumTouchTarget: CGFloat = 44
        static let placeholderOpacity: Double = 0.3
        static let pressedOpacity: Double = 0.7
        // Figma surface/grey-600 #525250.
        // swiftlint:disable:next no_magic_numbers
        static let disabledBackground = Color(.sRGB, red: 82 / 255, green: 82 / 255, blue: 80 / 255)
    }
}

extension Constants.ManualTokenEntry {
    // Figma content height excluding the native home-indicator safe area.
    // The sheet replaces this initial estimate with measured, scalable content.
    static let initialSheetHeight: CGFloat = 633
    static let contentSpacing: CGFloat = 48
    static let headerSpacing: CGFloat = 20
    static let formSpacing: CGFloat = 24
    static let fieldSpacing: CGFloat = 16
    static let buttonSpacing: CGFloat = 32
    static let progressSpacing: CGFloat = 8
    static let labelTracking: CGFloat = 0.24
    static let pasteVerticalPadding: CGFloat = 10
    static let pasteHitExpansion: CGFloat = 10
}
