import SwiftUI

/// An opt-in request from the presenting view, not from the sheet's content.
/// Removing that presenter also removes its preference, so no scene-global
/// visibility state can survive navigation or leak into another window.
struct ConnectionBackdropPreference: PreferenceKey {
    nonisolated static var defaultValue: Double { 0 }

    nonisolated static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }

    // Supplemental alpha beneath the system's modal dimmer. These are not
    // the Figma alpha values: the rendered composition must be compared.
    static let manualOpacity = 0.88
    static let savedOpacity = 0.76
}

/// Lives outside the NavigationStack so content AND navigation chrome receive
/// the same effect. Native sheets retain their own foreground and touch shield.
struct ConnectionSceneBackdrop: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var opacity: Double = 0
    private let blurRadius: CGFloat = 10
    private let transitionDuration: Double = 0.2
    // Figma Fade uses sRGB #080808.
    // swiftlint:disable:next no_magic_numbers
    private let shade = Color(.sRGB, white: 8 / 255, opacity: 1)

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
    /// Manual frames 2989:19990 / 2989:20026; reusable destination-sheet geometry.
    /// Manual's shared palette is supplied explicitly, preserving other sheet callers.
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
        // Figma Surface/Grey600 in dark 2989:19990 and light 3051:54152.
        // swiftlint:disable no_magic_numbers
        private static let darkDisabledBackground = Color(.sRGB, red: 82 / 255, green: 82 / 255, blue: 80 / 255)
        private static let lightDisabledBackground = Color(.sRGB, red: 186 / 255, green: 186 / 255, blue: 183 / 255)
        private static let lightDisabledForeground = Color(.sRGB, red: 240 / 255, green: 240 / 255, blue: 235 / 255)
        // swiftlint:enable no_magic_numbers

        static func disabledBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark ? darkDisabledBackground : lightDisabledBackground
        }

        static func disabledForeground(for scheme: ColorScheme) -> Color {
            (scheme == .dark ? Constants.Pairing.onAccent : lightDisabledForeground).opacity(placeholderOpacity)
        }

        // Nil sheet overrides retain the appearance used by unmodified destinations such as Details.
        static func defaultBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark ? Constants.Pairing.background(for: scheme) : Theme.background(for: scheme)
        }

        static func defaultForeground(for scheme: ColorScheme) -> Color {
            scheme == .dark ? Constants.Pairing.foreground(for: scheme) : Theme.foreground(for: scheme)
        }
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

    // Field labels use Grey400 in light mode, distinct from the Grey500 subtitle.
    // swiftlint:disable:next no_magic_numbers
    private static let lightLabelForeground = Color(.sRGB, red: 82 / 255, green: 82 / 255, blue: 80 / 255)

    static func labelForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.mutedForeground(for: scheme) : lightLabelForeground
    }
}
