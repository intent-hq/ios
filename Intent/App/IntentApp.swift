import SwiftUI
import UIKit

@main
struct IntentApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(RemoteNotificationsAppDelegate.self) private var appDelegate
    #endif

    init() {
        ConversationTrace.emit("AppStarted", "")
        LifecycleDiagnostics.sessionStarted()
        #if DEBUG
        DemoConnectionLoss.seedSavedMachineIfNeeded()
        DemoSettings.seedConnectionsIfNeeded()
        DemoStartupConnection.seedSavedMachineIfNeeded()
        #endif
        #if os(iOS)
        LocalNotificationService.shared.onAuthorized = {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
        _ = NotificationManager.shared
        BackendSessionRegistry.shared.onSessionCreated = { session in
            NotificationManager.shared.attachSessionObserver(for: session)
            #if os(iOS)
            AgentLiveActivityController.shared.attach(session)
            PushRelayController.shared.attach(session)
            #endif
        }
        BackendSessionRegistry.shared.onSessionTeardown = { session in
            if let backendID = session.backendID {
                NotificationManager.shared.detachSessionObserver(for: backendID)
                #if os(iOS)
                AgentLiveActivityController.shared.detach(backendID)
                PushRelayController.shared.detach(backendID)
                #endif
            }
        }
        #if os(iOS)
        BackendSessionRegistry.shared.onBackendsRemoved = { backendIDs in
            PushRelayController.shared.connectionsRemoved(backendIDs)
        }
        PushRelayController.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup(for: BackendID.self) { $backendID in
            BackendWindowRoot(
                backendID: $backendID,
                networkAvailability: Self.networkAvailability
            )
                .buttonStyle(IntentContentButtonStyle())
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

    private static var networkAvailability: NetworkAvailability {
        #if DEBUG
        DemoConnectionLoss.networkAvailability ?? .shared
        #else
        .shared
        #endif
    }
}

enum WindowRetargetRoute: Equatable {
    case openTargetWindow
    case rebindInPlace
    case replaceWindow

    nonisolated static var platformOpensSeparateBackendWindows: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    static func route(
        currentBackendID: BackendID?,
        target: BackendID,
        supportsMultipleWindows: Bool,
        choosesBackendInPlace: Bool = false,
        opensSeparateBackendWindows: Bool = platformOpensSeparateBackendWindows
    ) -> Self {
        guard supportsMultipleWindows else { return .rebindInPlace }
        guard let currentBackendID else { return .replaceWindow }
        guard opensSeparateBackendWindows, !choosesBackendInPlace, currentBackendID != target else {
            return .rebindInPlace
        }
        return .openTargetWindow
    }
}

struct SessionWindowRoot: View {
    let session: BackendSession
    let networkAvailability: NetworkAvailability
    let retargetWindow: ((BackendID, Bool) -> Void)?
    let retargetRoute: ((BackendID, Bool) -> WindowRetargetRoute)?
    let returnToSavedMachines: (() -> Void)?
    @State private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(
        session: BackendSession,
        networkAvailability: NetworkAvailability = .shared,
        retargetWindow: ((BackendID, Bool) -> Void)? = nil,
        retargetRoute: ((BackendID, Bool) -> WindowRetargetRoute)? = nil,
        returnToSavedMachines: (() -> Void)? = nil,
        startingAtSavedMachines: Bool = false
    ) {
        self.session = session
        self.networkAvailability = networkAvailability
        self.retargetWindow = retargetWindow
        self.retargetRoute = retargetRoute
        self.returnToSavedMachines = returnToSavedMachines
        _coordinator = State(initialValue: session.makeCoordinator(startingAtSavedMachines: startingAtSavedMachines))
    }

    var body: some View {
        RootView(networkAvailability: networkAvailability)
            .environment(session)
            .environment(coordinator)
            #if DEBUG
            .environment(\.scriptMonitorPresentationDate, DemoScriptMonitorFixtures.configuredPresentationDate())
            #endif
            .onAppear {
                let coordinator = coordinator
                coordinator.retargetWindow = retargetWindow.map { hook in
                    { [weak coordinator] target in hook(target, coordinator?.choosesBackendInPlace ?? false) }
                }
                coordinator.retargetRoute = retargetRoute.map { hook in
                    { [weak coordinator] target in hook(target, coordinator?.choosesBackendInPlace ?? false) }
                }
                coordinator.returnWindowToSavedMachines = returnToSavedMachines
            }
            .onOpenURL { url in
                if let link = AgentActivityLink(url: url) {
                    NotificationManager.shared.routeAgentSelection(
                        agentId: link.agentId,
                        workspaceId: link.workspaceId,
                        agentName: link.agentName,
                        connectionId: link.connectionId
                    )
                } else {
                    coordinator.handleIncomingURL(url)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    coordinator.onScenePhaseActive()
                } else {
                    coordinator.onScenePhaseNotActive()
                    if phase == .background { coordinator.onScenePhaseBackground() }
                }
                #if DEBUG
                DemoConnectionLoss.sceneChanged(phase, connection: session.connection)
                #endif
            }
    }
}

struct BackendWindowRoot: View {
    private static let replacementConnectionPollLimit = 20

    @AppStorage("appThemePreference") private var themePreference = "system"
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

    private var resolvedColorScheme: ColorScheme? {
        switch themePreference {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        Group {
            if isRemoved {
                RemovedBackendPlaceholderView(onClose: closeRemovedWindow)
            } else if let session = windowSession.session {
                SessionWindowRoot(
                    session: session,
                    networkAvailability: windowSession.networkAvailability,
                    retargetWindow: retarget(to:choosingInPlace:),
                    retargetRoute: retargetRoute(for:choosingInPlace:),
                    returnToSavedMachines: windowSession.returnToSavedMachines,
                    startingAtSavedMachines: windowSession.isShowingSavedMachines
                )
                    .id(ObjectIdentifier(session))
            } else {
                Color.clear
            }
        }
        .preferredColorScheme(resolvedColorScheme)
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
            #if DEBUG
            if let demoBackendID = DemoSettings.consumeStartupBackendID() ?? DemoStartupConnection.consumeStartupBackendID() {
                restoresSavedMachines = false
                backendID = demoBackendID
            }
            #endif
            restoresSavedMachines = windowSession.restoreSavedMachines(restoresSavedMachines)
            if backendID == nil, !windowSession.isShowingSavedMachines,
               let lastUsed = PersistenceManager.shared.lastUsedConnection() {
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

    private func bindCurrentBackend() {
        if let backendID, !windowSession.isShowingSavedMachines {
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

    private func retarget(to target: BackendID, choosingInPlace: Bool) {
        let route = retargetRoute(for: target, choosingInPlace: choosingInPlace)
        windowSession.prepareForSelection(to: target, route: route)
        switch route {
        case .openTargetWindow:
            openWindow(value: target)
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

    private func retargetRoute(for target: BackendID, choosingInPlace: Bool) -> WindowRetargetRoute {
        WindowRetargetRoute.route(
            currentBackendID: backendID,
            target: target,
            supportsMultipleWindows: supportsMultipleWindows,
            choosesBackendInPlace: choosingInPlace || windowSession.isShowingSavedMachines
        )
    }

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

enum RemovedWindowCloseAction: Equatable {
    case dismiss
    case retargetToPairing

    static func forWindowCounts(
        connectedWindowScenes: Int,
        attachedRemovedBackendWindows: Int
    ) -> Self {
        let surviving = connectedWindowScenes - attachedRemovedBackendWindows - 1
        return surviving > 0 ? .dismiss : .retargetToPairing
    }
}

private struct RemovedBackendPlaceholderView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Constants.Root.reconnectPanelSpacing) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Connection Removed")
                .interFont(Constants.Typography.bodyM.withFace(.semibold))
            Text("This connection is no longer saved.")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onClose) {
                Text("Close Window")
                    .interFont(Constants.Typography.bodyS)
            }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
        }
        .padding()
    }
}
