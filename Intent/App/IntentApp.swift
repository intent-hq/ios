import SwiftUI

@main
struct IntentApp: App {
    /// The default window's session: the registry's default session, whose
    /// objects every view and view model below reads from the environment.
    /// This is the app's single root injection site for session state.
    @State private var session = BackendSessionRegistry.shared.defaultSession
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
            SessionWindowRoot(session: session)
                .preferredColorScheme(resolvedColorScheme)
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

/// Root of one window (scene): owns that window's `AppCoordinator` so windows
/// sharing a session navigate independently (spec "State split" / decision 1b).
/// `@State` keeps one coordinator per scene; the session's restoration claim
/// is consumed lazily on first use, so coordinators built for discarded view
/// constructions never spend it. Scene phase and incoming URLs are handled
/// here so each window's coordinator sees its own scene's lifecycle.
struct SessionWindowRoot: View {
    let session: BackendSession
    @State private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(session: BackendSession) {
        self.session = session
        _coordinator = State(initialValue: session.makeCoordinator())
    }

    var body: some View {
        RootView()
            .environment(session)
            .environment(coordinator)
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
    }
}
