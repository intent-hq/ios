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

        // Pinned-backend windows, opened via openWindow(value:) from the
        // connections list (visionOS and iPad; iPhone never offers multiple
        // scenes). Each window attaches the backend's shared session through
        // the registry and owns its own coordinator via SessionWindowRoot.
        WindowGroup(for: BackendID.self) { $backendID in
            Group {
                if let backendID {
                    PinnedBackendWindowRoot(backendID: backendID)
                } else {
                    // Restoration lost the value: behave as a duplicated
                    // default window (active-connection semantics).
                    SessionWindowRoot(session: session)
                }
            }
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

/// Root of one pinned-backend window: attaches the backend's shared session
/// through the registry on appear (creating it on first attach, refcounted
/// across windows) and releases it on disappear so the registry tears the
/// session down when the last window closes. Guards keep the attach/detach
/// pair balanced if either callback fires more than once. Navigation is per
/// window via SessionWindowRoot once the session is attached.
///
/// Backend removal (spec decision 2): when the registry marks this window's
/// backend removed — user delete, log off, synced tombstone, or (on appear)
/// a restored window whose saved record no longer exists — the session is
/// released immediately (dropping the connection via the normal detach path)
/// and the window dismisses itself via `dismissWindow(value:)`. If the
/// dismissal cannot be delivered, the "connection removed" placeholder
/// remains with a manual Close Window button.
struct PinnedBackendWindowRoot: View {
    let backendID: BackendID
    @State private var session: BackendSession?
    @Environment(\.dismissWindow) private var dismissWindow

    private var isRemoved: Bool {
        BackendSessionRegistry.shared.isBackendRemoved(backendID)
    }

    var body: some View {
        Group {
            if isRemoved {
                RemovedBackendPlaceholderView()
            } else if let session {
                SessionWindowRoot(session: session)
            } else {
                Color.clear
            }
        }
        .onAppear {
            // A window restored after its backend was removed while the app
            // was not running: mark it so the shared auto-close path below
            // takes over.
            if !isRemoved,
               !PersistenceManager.shared.loadConnections()
                   .contains(where: { $0.id == backendID.connectionID }) {
                BackendSessionRegistry.shared.markBackendRemoved(backendID)
                return
            }
            guard !isRemoved, session == nil else { return }
            session = BackendSessionRegistry.shared.attach(backendID)
        }
        // initial: true covers a mark set before this window ever rendered
        // (removal racing a window that is still opening or being restored).
        .onChange(of: isRemoved, initial: true) { _, removed in
            guard removed else { return }
            releaseSession()
            dismissWindow(value: backendID)
        }
        .onDisappear {
            releaseSession()
        }
    }

    private func releaseSession() {
        guard session != nil else { return }
        session = nil
        BackendSessionRegistry.shared.detach(backendID)
    }
}

/// Fallback surface for a pinned window whose backend was removed but whose
/// programmatic dismissal could not be delivered (spec decision 2): names
/// the state and offers a manual close.
private struct RemovedBackendPlaceholderView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: Constants.Root.reconnectPanelSpacing) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Connection Removed")
                .font(.headline)
            Text("This connection is no longer saved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close Window") { dismissWindow() }
                .buttonStyle(.bordered)
        }
        .padding()
    }
}
