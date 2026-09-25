import SwiftUI

/// Resolves appearance at each window's existing theme boundary. Reading the
/// current subtree preference (rather than storing visibility) also clears the
/// override when navigation or backend retargeting removes the splash.
struct LaunchAppearanceModifier: ViewModifier {
    let preferredColorScheme: ColorScheme?

    struct SplashVisibleKey: PreferenceKey {
        nonisolated static var defaultValue: Bool { false }

        nonisolated static func reduce(value: inout Bool, nextValue: () -> Bool) {
            value = value || nextValue()
        }
    }

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(SplashVisibleKey.self) { isShowingSplash in
            Color.clear.preferredColorScheme(isShowingSplash ? .light : preferredColorScheme)
        }
    }
}
