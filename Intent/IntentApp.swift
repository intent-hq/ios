import SwiftUI

@main
struct IntentApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @AppStorage("appThemePreference") private var themePreference: String = "system"

    private var resolvedColorScheme: ColorScheme? {
        switch themePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            let _ = NotificationManager.shared
            RootView()
                .environmentObject(coordinator)
                .environmentObject(ConnectionManager.shared)
                .preferredColorScheme(resolvedColorScheme)
        }
    }
}
