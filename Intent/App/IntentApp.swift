import SwiftUI
import UIKit

@main
struct IntentApp: App {
    @AppStorage("appThemePreference") private var themePreference: String = "system"

    init() {
        LifecycleDiagnostics.sessionStarted()
        DemoConnectionLoss.seedSavedMachineIfNeeded()
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
            BackendWindowRoot(
                backendID: $backendID,
                networkAvailability: DemoConnectionLoss.networkAvailability ?? .shared
            )
                .preferredColorScheme(resolvedColorScheme)
                #if os(visionOS)
                .frame(
                    minWidth: Constants.Root.visionMinimumWindowWidth,
                    minHeight: Constants.Root.visionMinimumWindowHeight
                )
                #endif
        }
        #if os(visionOS)
        .defaultSize(
            width: Constants.Root.visionDefaultWindowWidth,
            height: Constants.Root.visionDefaultWindowHeight
        )
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// The v2 retarget policy for a switch/pair action performed in a window:
/// where multiple windows are supported, a bound window never retargets —
/// the target backend's own window is opened or raised — and an unbound
/// (pairing) window is REPLACED by the target's own window rather than
/// rebound: `openWindow(value:)` only matches windows whose scene value was
/// set at creation, so a window rebound via the scene-value binding write
/// is never raised again — later switches to its backend open duplicate
/// windows (observed on visionOS). Replacing keeps every bound multi-window
/// scene natively valued. Single-window platforms (iPhone; iPad without
/// multi-window) rebind the one window in place.
enum WindowRetargetRoute: Equatable {
    case openTargetWindow
    case rebindInPlace
    case replaceWindow

    static func route(
        currentBackendID: BackendID?,
        target: BackendID,
        supportsMultipleWindows: Bool
    ) -> Self {
        guard supportsMultipleWindows else { return .rebindInPlace }
        guard let current = currentBackendID else { return .replaceWindow }
        return current == target ? .rebindInPlace : .openTargetWindow
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
    let networkAvailability: NetworkAvailability
    let retargetWindow: ((BackendID) -> Void)?
    let returnToSavedMachines: (() -> Void)?
    @State private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(
        session: BackendSession,
        networkAvailability: NetworkAvailability = .shared,
        retargetWindow: ((BackendID) -> Void)? = nil,
        returnToSavedMachines: (() -> Void)? = nil,
        startingAtSavedMachines: Bool = false
    ) {
        self.session = session
        self.networkAvailability = networkAvailability
        self.retargetWindow = retargetWindow
        self.returnToSavedMachines = returnToSavedMachines
        _coordinator = State(initialValue: session.makeCoordinator(startingAtSavedMachines: startingAtSavedMachines))
    }

    var body: some View {
        RootView(networkAvailability: networkAvailability)
            .environment(session)
            .environment(coordinator)
            .onAppear {
                coordinator.retargetWindow = retargetWindow
                coordinator.returnWindowToSavedMachines = returnToSavedMachines
            }
            .onOpenURL { url in
                coordinator.handleIncomingURL(url)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    coordinator.onScenePhaseActive()
                } else {
                    coordinator.onScenePhaseNotActive()
                    if phase == .background { coordinator.onScenePhaseBackground() }
                }
                DemoConnectionLoss.sceneChanged(phase, connection: session.connection)
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
/// Returning Home releases the attachment without rewriting the native
/// scene value. The per-scene Home flag restores an unbound pairing session
/// instead of auto-connecting; selecting the native backend reattaches it.
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
    private static let replacementConnectionPollLimit = 20

    @Binding var backendID: BackendID?
    @State private var windowSession: BackendWindowSession
    @SceneStorage("backendWindowShowsSavedMachines") private var restoresSavedMachines = false
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    init(backendID: Binding<BackendID?>, networkAvailability: NetworkAvailability = .shared) {
        _backendID = backendID
        _windowSession = State(initialValue: BackendWindowSession(networkAvailability: networkAvailability))
    }

    private var isRemoved: Bool {
        guard let backendID,
              !restoresSavedMachines, !windowSession.isShowingSavedMachines else { return false }
        return BackendSessionRegistry.shared.isBackendRemoved(backendID)
    }

    var body: some View {
        Group {
            if isRemoved {
                RemovedBackendPlaceholderView(onClose: closeRemovedWindow)
            } else if let session = windowSession.session {
                SessionWindowRoot(
                    session: session,
                    networkAvailability: windowSession.networkAvailability,
                    retargetWindow: retarget,
                    returnToSavedMachines: windowSession.returnToSavedMachines,
                    startingAtSavedMachines: windowSession.isShowingSavedMachines
                )
                    // A rebind must build a fresh window root (new
                    // coordinator over the new session), not update the old
                    // one in place.
                    .id(ObjectIdentifier(session))
            } else {
                Color.clear
            }
        }
        .background {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                WindowSceneTitle(title: windowSession.sceneTitle)
                    .frame(width: 0, height: 0)
            }
            #endif
        }
        .onAppear {
            windowSession.updateNetworkObservation(for: scenePhase)
            if restoresSavedMachines {
                windowSession.returnToSavedMachines()
            }
            if backendID == nil, !windowSession.isShowingSavedMachines,
               let lastUsed = PersistenceManager.shared.lastUsedConnection() {
                // Plain launch (no restored scene value): bind to the
                // last-used backend; bindCurrentBackend runs via onChange.
                backendID = BackendID(lastUsed.id)
                return
            }
            bindCurrentBackend()
        }
        .onChange(of: scenePhase) { _, phase in
            windowSession.updateNetworkObservation(for: phase)
        }
        .onChange(of: windowSession.isShowingSavedMachines) { _, showsSavedMachines in
            restoresSavedMachines = showsSavedMachines
        }
        .onChange(of: backendID) { _, _ in
            windowSession.prepareToRebind()
            bindCurrentBackend()
        }
        // initial: true covers a mark set before this window ever rendered
        // (removal racing a window that is still opening or being restored).
        .onChange(of: isRemoved, initial: true) { _, removed in
            guard removed else { return }
            windowSession.release()
            closeRemovedWindow()
        }
        .onDisappear {
            windowSession.stopNetworkObservation()
            windowSession.release()
        }
    }

    /// Attaches the session for the current scene value: the backend's
    /// shared session when bound, else a fresh transient pairing session.
    private func bindCurrentBackend() {
        if let backendID, !windowSession.isShowingSavedMachines {
            // A window restored (or retargeted) after its backend's record
            // was removed: mark it so the shared auto-close path takes over.
            if !isRemoved,
               !PersistenceManager.shared.loadConnections()
                   .contains(where: { $0.id == backendID.connectionID }) {
                BackendSessionRegistry.shared.markBackendRemoved(backendID)
                return
            }
            guard !isRemoved else { return }
        }
        windowSession.bind(to: backendID)
    }

    /// The coordinator's retarget hook: apply the v2 policy for switching
    /// this window to `target` (rebind in place, open/raise the target
    /// backend's own window, or replace this unbound pairing window with
    /// the target's own window so it stays raisable by value).
    private func retarget(to target: BackendID) {
        switch WindowRetargetRoute.route(
            currentBackendID: backendID,
            target: target,
            supportsMultipleWindows: supportsMultipleWindows
        ) {
        case .openTargetWindow:
            openWindow(value: target)
            if windowSession.isShowingSavedMachines {
                // A new pairing may have used Home's transient connection.
                // The target now owns its own session; Home must stay idle.
                windowSession.release()
                windowSession.bind(to: nil)
            }
        case .replaceWindow:
            openWindow(value: target)
            dismissWhenReplacementConnects()
        case .rebindInPlace:
            if backendID == target, windowSession.isShowingSavedMachines {
                windowSession.rebind(to: target)
            } else {
                backendID = target
            }
        }
    }

    /// Dismisses this (pairing) window once the replacement window's scene
    /// has connected: the scene opened by `openWindow` connects
    /// asynchronously, and dismissing the app's only window is a system
    /// no-op — a synchronous `dismissWindow()` right after `openWindow`
    /// leaves the pairing window behind (observed on visionOS).
    private func dismissWhenReplacementConnects() {
        Task { @MainActor in
            for _ in 0..<Self.replacementConnectionPollLimit {
                let scenes = UIApplication.shared.connectedScenes
                    .filter { $0 is UIWindowScene }
                    .count
                if scenes > 1 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            dismissWindow()
        }
    }

    /// Close-or-rebind decision for a removed backend: with other windows
    /// open, dismiss this one; the app's last window rebinds to the pairing
    /// surface instead of leaving zero windows. Sibling windows still
    /// attached to the removed backend (this window has already detached)
    /// are excluded from the count: they will run this same decision and
    /// cannot be relied on to survive, so two windows on the removed
    /// backend never race both into `.dismiss` and end at zero windows —
    /// the first to decide rebinds to pairing, and the later one counts it
    /// as a surviving window and dismisses.
    private func closeRemovedWindow() {
        guard let removedID = backendID else { return }
        let windowScenes = UIApplication.shared.connectedScenes
            .filter { $0 is UIWindowScene }
            .count
        switch RemovedWindowCloseAction.forWindowCounts(
            connectedWindowScenes: windowScenes,
            attachedRemovedBackendWindows:
                BackendSessionRegistry.shared.attachmentCount(for: removedID)
        ) {
        case .dismiss:
            dismissWindow(value: removedID)
        case .retargetToPairing:
            backendID = nil
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

    /// `connectedWindowScenes` is the number of window scenes connected to
    /// the app, including the removed window itself;
    /// `attachedRemovedBackendWindows` counts the sibling windows still
    /// attached to the removed backend (the deciding window has already
    /// detached). Only windows outside both — scenes that survive the
    /// removal — justify a dismiss.
    static func forWindowCounts(
        connectedWindowScenes: Int,
        attachedRemovedBackendWindows: Int
    ) -> Self {
        let surviving = connectedWindowScenes - attachedRemovedBackendWindows - 1
        return surviving > 0 ? .dismiss : .retargetToPairing
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
                .accessibilityHidden(true)
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
