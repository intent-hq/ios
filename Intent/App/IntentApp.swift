import SwiftUI

@main
struct IntentApp: App {
    @State private var coordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appThemePreference") private var themePreference: String = "system"

    init() {
        _ = NotificationManager.shared
    }

    private var resolvedColorScheme: ColorScheme? {
        switch themePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
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
                    } else {
                        coordinator.onScenePhaseNotActive()
                    }
                }
                #if os(visionOS)
                .frame(
                    minWidth: Constants.Root.visionMinimumWindowWidth,
                    minHeight: Constants.Root.visionMinimumWindowHeight)
                #endif
        }
        #if os(visionOS)
        .defaultSize(
            width: Constants.Root.visionDefaultWindowWidth,
            height: Constants.Root.visionDefaultWindowHeight)
        .windowResizability(.contentMinSize)
        #endif
    }
}
