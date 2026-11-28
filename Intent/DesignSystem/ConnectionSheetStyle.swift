import SwiftUI

struct ConnectionBackdropPreference: PreferenceKey {
    nonisolated static var defaultValue: Double { 0 }

    nonisolated static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }

    static let manualOpacity = 0.88
    static let savedOpacity = 0.76
}

struct ConnectionSceneBackdrop: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var opacity: Double = 0
    private let blurRadius: CGFloat = 10
    private let transitionDuration: Double = 0.2
    private static let shadeWhite: UInt32 = 0x08
    private let shade = Color(.sRGB, white: Constants.EightBitChannel.fraction(Self.shadeWhite), opacity: 1)

    private var usesCompactBackdrop: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    func body(content: Content) -> some View {
        let activeOpacity = usesCompactBackdrop ? opacity : 0
        content
            .blur(radius: activeOpacity > 0 && !reduceTransparency ? blurRadius : 0)
            .overlay {
                shade
                    .opacity(activeOpacity > 0 && reduceTransparency ? 1 : activeOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: transitionDuration), value: activeOpacity)
            .onPreferenceChange(ConnectionBackdropPreference.self) { opacity = $0 }
    }
}

extension Constants {
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
        private static let darkDisabledBackground = Color(sRGBHex: Constants.DesignPalette.darkGrey)
        private static let lightDisabledBackground = Color(sRGBHex: Constants.DesignPalette.lightDisabledGrey)
        private static let lightDisabledForeground = Color(sRGBHex: Constants.DesignPalette.paper)

        static func disabledBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark ? darkDisabledBackground : lightDisabledBackground
        }

        static func disabledForeground(for scheme: ColorScheme) -> Color {
            (scheme == .dark ? Constants.Pairing.onAccent : lightDisabledForeground).opacity(placeholderOpacity)
        }

        static func defaultBackground(for scheme: ColorScheme) -> Color {
            Constants.WorkspaceList.canvas(for: scheme)
        }

        static func defaultForeground(for scheme: ColorScheme) -> Color {
            scheme == .dark ? Constants.Pairing.foreground(for: scheme) : Theme.foreground(for: scheme)
        }
    }
}

extension Constants.ManualTokenEntry {
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

    private static let lightLabelForeground = Color(sRGBHex: Constants.DesignPalette.darkGrey)

    static func labelForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.mutedForeground(for: scheme) : lightLabelForeground
    }
}
