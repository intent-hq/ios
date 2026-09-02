import SwiftUI

@main
struct IntentApp: App {
    @State private var coordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase
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
                .environment(coordinator)
                .environment(ConnectionManager.shared)
                .preferredColorScheme(resolvedColorScheme)
                .onOpenURL { url in
                    coordinator.handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        coordinator.onScenePhaseActive()
                    }
                }
        }
    }
}
