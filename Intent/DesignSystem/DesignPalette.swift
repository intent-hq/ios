import SwiftUI

extension Constants {
    /// Exact 8-bit sRGB values from the Figma exports, written as `0xRRGGBB`
    /// so each constant stays directly comparable with the design file.
    nonisolated enum DesignPalette {
        static let ink: UInt32 = 0x080808
        static let darkCanvas: UInt32 = 0x161616
        static let homeMenuFade: UInt32 = 0x1A1A19
        static let darkSurface: UInt32 = 0x272727
        static let charcoalGrey: UInt32 = 0x3D3D3C
        static let darkGrey: UInt32 = 0x525250
        static let mutedGrey: UInt32 = 0x8C8C89
        static let lightDisabledGrey: UInt32 = 0xBABAB7
        static let paper: UInt32 = 0xF0F0EB
        static let accentLime: UInt32 = 0xDDEC61
        static let connectedGreen: UInt32 = 0x6FA356
        static let blockerOrange: UInt32 = 0xE87F39
        static let blockerBody: UInt32 = 0x857367
    }

    /// Converts 8-bit design channels to the unit fractions SwiftUI expects.
    nonisolated enum EightBitChannel {
        private static let maximum: Double = 255
        private static let mask: UInt32 = 0xFF
        private static let redShift: UInt32 = 16
        private static let greenShift: UInt32 = 8

        /// `value / 255`, e.g. an exported alpha byte such as `0x26`.
        static func fraction(_ value: UInt32) -> Double {
            Double(value & mask) / maximum
        }

        static func red(_ hex: UInt32) -> Double { fraction(hex >> redShift) }
        static func green(_ hex: UInt32) -> Double { fraction(hex >> greenShift) }
        static func blue(_ hex: UInt32) -> Double { fraction(hex) }
    }
}

extension Color {
    /// An opaque sRGB color from a `0xRRGGBB` design value.
    nonisolated init(sRGBHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Constants.EightBitChannel.red(hex),
            green: Constants.EightBitChannel.green(hex),
            blue: Constants.EightBitChannel.blue(hex)
        )
    }
}
