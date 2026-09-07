import SwiftUI
import UIKit

@main
struct IntentApp: App {
    @AppStorage("appThemePreference") private var themePreference: String = "system"

    init() {
        _ = NotificationManager.shared
        // Aggregate agent alerts across every live backend session: each
        // session attaches an observer on creation and detaches on
        // last-window teardown (window model v2: there is no default
        // session; transient pairing sessions carry no backend to observe).
        BackendSessionRegistry.shared.onSessionCreated = { session in
            NotificationManager.shared.attachSessionObserver(for: session)
        }
        BackendSessionRegistry.shared.onSessionTeardown = { session in
            if let backendID = session.backendID {
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
        // Window model v2: every window is bound to exactly one backend.
        // `openWindow(value:)` raises the existing window for a backend or
        // opens a new one; system restoration reopens the last open windows
        // with their values. A nil value (plain launch, restoration loss)
        // resolves to the last-used backend, else runs a transient pairing
        // session until a pairing completes and rebinds the window.
        WindowGroup(for: BackendID.self) { $backendID in
            BackendWindowRoot(backendID: $backendID)
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

/// The v2 retarget policy for a switch/pair action performed in a window:
/// where multiple windows are supported, a bound window never retargets —
/// the target backend's own window is opened or raised. Single-window
/// platforms (iPhone; iPad without multi-window) and unbound (pairing)
/// windows rebind in place.
enum WindowRetargetRoute: Equatable {
    case rebindInPlace
    case openTargetWindow

    static func route(
        currentBackendID: BackendID?,
        target: BackendID,
        supportsMultipleWindows: Bool
    ) -> WindowRetargetRoute {
        guard supportsMultipleWindows,
              let current = currentBackendID,
              current != target
        else { return .rebindInPlace }
        return .openTargetWindow
    }
}

/// Root of one window (scene): owns that window's `AppCoordinator` so windows
/// sharing a session navigate independently (spec "State split"). `@State`
/// keeps one coordinator per scene; the session's restoration claim is
/// consumed lazily on first use, so coordinators built for discarded view
/// constructions never spend it. Scene phase and incoming URLs are handled
/// here so each window's coordinator sees its own scene's lifecycle.
struct SessionWindowRoot: View {
    let session: BackendSession
    let retargetWindow: ((BackendID) -> Void)?
    @State private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(session: BackendSession, retargetWindow: ((BackendID) -> Void)? = nil) {
        self.session = session
        self.retargetWindow = retargetWindow
        _coordinator = State(initialValue: session.makeCoordinator())
    }

    var body: some View {
        RootView()
            .environment(session)
            .environment(coordinator)
            .onAppear {
                coordinator.retargetWindow = retargetWindow
            }
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

/// Root of one backend-bound window (window model v2). The scene value is
/// the binding contract: a bound window attaches its backend's shared
/// session through the registry (created on first attach, refcounted across
/// windows) and releases it when the window closes or rebinds, so the
/// registry tears the session down at zero windows. A nil scene value
/// (plain launch, restoration loss) is resolved once to the last-used
/// backend; with none paired the window runs a transient pairing session
/// until a pairing completes and rebinds it via the retarget hook.
///
/// Backend removal: when the registry marks this window's backend removed —
/// user delete, log off, synced tombstone, or (on bind) a restored window
/// whose saved record no longer exists — the session is released
/// immediately (dropping the connection via the normal detach path) and the
/// window dismisses itself via `dismissWindow(value:)`; the app's last
/// window rebinds to the pairing surface instead of leaving zero windows.
/// If a dismissal cannot be delivered, the "connection removed" placeholder
/// remains with a manual Close Window button applying the same decision.
struct BackendWindowRoot: View {
    @Binding var backendID: BackendID?
    @State private var session: BackendSession?
    @State private var pairingSession: BackendSession?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    private var isRemoved: Bool {
        guard let backendID else { return false }
        return BackendSessionRegistry.shared.isBackendRemoved(backendID)
    }

    var body: some View {
        Group {
            if isRemoved {
                RemovedBackendPlaceholderView(onClose: closeRemovedWindow)
            } else if let session = session ?? pairingSession {
                SessionWindowRoot(session: session, retargetWindow: retarget)
                    // A rebind must build a fresh window root (new
                    // coordinator over the new session), not update the old
                    // one in place.
                    .id(ObjectIdentifier(session))
            } else {
                Color.clear
            }
        }
        .onAppear {
            if backendID == nil,
               let lastUsed = PersistenceManager.shared.lastUsedConnection() {
                // Plain launch (no restored scene value): bind to the
                // last-used backend; bindCurrentBackend runs via onChange.
                backendID = BackendID(lastUsed.id)
                return
            }
            bindCurrentBackend()
        }
        .onChange(of: backendID) { oldValue, _ in
            releaseSession(oldValue)
            bindCurrentBackend()
        }
        // initial: true covers a mark set before this window ever rendered
        // (removal racing a window that is still opening or being restored).
        .onChange(of: isRemoved, initial: true) { _, removed in
            guard removed else { return }
            releaseSession(backendID)
            closeRemovedWindow()
        }
        .onDisappear {
            releaseSession(backendID)
        }
    }

    /// Attaches the session for the current scene value: the backend's
    /// shared session when bound, else a fresh transient pairing session.
    private func bindCurrentBackend() {
        if let backendID {
            // A window restored (or retargeted) after its backend's record
            // was removed: mark it so the shared auto-close path takes over.
            if !isRemoved,
               !PersistenceManager.shared.loadConnections()
                   .contains(where: { $0.id == backendID.connectionID }) {
                BackendSessionRegistry.shared.markBackendRemoved(backendID)
                return
            }
            guard !isRemoved, session == nil else { return }
            session = BackendSessionRegistry.shared.attach(backendID)
        } else {
            guard pairingSession == nil else { return }
            pairingSession = BackendSessionRegistry.shared.makePairingSession()
        }
    }

    /// The coordinator's retarget hook: apply the v2 policy for switching
    /// this window to `target` (rebind in place vs open/raise the target
    /// backend's own window).
    private func retarget(to target: BackendID) {
        switch WindowRetargetRoute.route(
            currentBackendID: backendID, target: target,
            supportsMultipleWindows: supportsMultipleWindows)
        {
        case .openTargetWindow:
            openWindow(value: target)
        case .rebindInPlace:
            backendID = target
        }
    }

    /// Close-or-rebind decision for a removed backend: with other windows
    /// open, dismiss this one; the app's last window rebinds to the pairing
    /// surface instead of leaving zero windows.
    private func closeRemovedWindow() {
        guard let removedID = backendID else { return }
        let windowScenes = UIApplication.shared.connectedScenes
            .filter { $0 is UIWindowScene }
            .count
        switch RemovedWindowCloseAction.forOpenWindowCount(windowScenes) {
        case .dismiss:
            dismissWindow(value: removedID)
        case .retargetToPairing:
            backendID = nil
        }
    }

    private func releaseSession(_ id: BackendID?) {
        if session != nil, let id {
            session = nil
            BackendSessionRegistry.shared.detach(id)
        }
        if let pairing = pairingSession {
            pairingSession = nil
            pairing.teardown()
        }
    }
}

/// What removing a window's backend does to the window (window model v2):
/// with other windows open, `dismissWindow(value:)` closes it; the app's
/// last window rebinds to the pairing surface instead — never zero windows,
/// never a silently dead surface.
enum RemovedWindowCloseAction: Equatable {
    case dismiss
    case retargetToPairing

    /// `count` is the number of window scenes connected to the app,
    /// including the removed window itself.
    static func forOpenWindowCount(_ count: Int) -> RemovedWindowCloseAction {
        count > 1 ? .dismiss : .retargetToPairing
    }
}

/// Fallback surface for a window whose backend was removed but whose
/// programmatic dismissal could not be delivered: names the state and
/// offers a manual close that works even as the last window.
private struct RemovedBackendPlaceholderView: View {
    let onClose: () -> Void

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
            Button("Close Window") { onClose() }
                .buttonStyle(.bordered)
        }
        .padding()
    }
}
