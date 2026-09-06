import SwiftUI

@main
struct IntentApp: App {
    /// The default window's session: the registry's default session, whose
    /// objects every view and view model below reads from the environment.
    /// This is the app's single root injection site for session state.
    @State private var session = BackendSessionRegistry.shared.defaultSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appThemePreference") private var themePreference: String = "system"

    init() {
        _ = NotificationManager.shared
        // Aggregate agent alerts across every live backend session: pinned
        // sessions (visionOS auxiliary windows) attach an observer on
        // creation and detach on last-window teardown; the default session
        // is already observed by NotificationManager's own init.
        BackendSessionRegistry.shared.onSessionCreated = { session in
            NotificationManager.shared.attachSessionObserver(for: session)
        }
        BackendSessionRegistry.shared.onSessionTeardown = { session in
            if let backendID = session.pinnedBackendID {
                NotificationManager.shared.detachSessionObserver(for: backendID)
            }
        }
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
                .environment(session)
                .environment(session.coordinator)
                .preferredColorScheme(resolvedColorScheme)
                .onOpenURL { url in
                    session.coordinator.handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        session.coordinator.onScenePhaseActive()
                    } else {
                        session.coordinator.onScenePhaseNotActive()
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
