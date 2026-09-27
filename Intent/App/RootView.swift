import SwiftUI

struct RootView: View {
    var networkAvailability: NetworkAvailability = .shared
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.colorScheme) var colorScheme
    // Multi-window tap routing (spec decision 5): false on iPhone, so alert
    // taps there always navigate in place — unchanged semantics.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @State private var notificationManager = NotificationManager.shared
    /// Token of this window's selection-handler registration, so disappear
    /// removes only this window's registration — never a successor's.
    @State private var selectionHandlerToken: UUID?
    @State private var isSearchingWorkspaces = false
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var showingWorkspaceDetail = false // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var showingConversation = false // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var conversationAgentId: String = "" // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var conversationWorkspaceId: String = "" // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var conversationAgentName: String = "" // swiftlint:disable:this private_swiftui_state
    // Compact (iPhone) note detail navigation — uses isPresented instead of noteStack
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var showingNoteDetail = false // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var noteDetailNoteId: String = "" // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var noteDetailWorkspaceId: String = "" // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var noteDetailNoteTitle: String = "" // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var pendingConversationPush = false // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var pendingNoteDetailPush = false // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    /// True while syncNavigationState() tears down the conversation for the iPad
    /// re-push dance, so the user-back onChange handler doesn't misfire.
    @State var programmaticConversationDismiss = false // swiftlint:disable:this private_swiftui_state
    @State var handledConversationRequestId = 0 // swiftlint:disable:this private_swiftui_state
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var noteStack = NavigationPath() // swiftlint:disable:this private_swiftui_state

    var conversationDestination: some View {
        ConversationDestinationView(
            fallback: conversationAgentId.isEmpty ? nil : ConversationDestinationView.Target(
                agentId: conversationAgentId,
                workspaceId: conversationWorkspaceId,
                agentName: conversationAgentName
            ),
            session: session
        )
    }

    private var isWorkspaceFlow: Bool {
        switch coordinator.currentScreen {
        case .workspaceList, .workspaceDetail, .agentConversation, .noteDetail:
            return true
        default:
            return false
        }
    }

    /// True during the launch splash phases (loading and connecting), which
    /// share a single SplashArtView so animation playback doesn't reset between them.
    private var isLaunchSplash: Bool {
        switch coordinator.currentScreen {
        case .loading, .connecting:
            return true
        default:
            return false
        }
    }

    /// visionOS: the scene-anchored sound emitters — one for the
    /// agent-completion chime, one for the workspace attention cue; empty
    /// elsewhere.
    @ViewBuilder private var windowFeedbackEmitter: some View {
        #if os(visionOS)
        WindowFeedbackSoundEmitter(eventID: feedbackEventForThisWindow?.id)
        WindowFeedbackSoundEmitter(eventID: session.attentionCueCenter.windowCueEvent?.id)
        #endif
    }

    #if os(visionOS)
    /// The manager's latest feedback request when this window is the one
    /// that must emit it — the same per-window decision as toast rendering
    /// (windowPresentsAlert); every other window gets nil.
    private var feedbackEventForThisWindow: NotificationManager.FeedbackEvent? {
        guard let event = notificationManager.windowFeedbackEvent,
              NotificationManager.windowPresentsAlert(
                  source: event.sourceBackendID,
                  windowBackendID: session.backendID,
                  supportsMultipleWindows: supportsMultipleWindows
              )
        else { return nil }
        return event
    }
    #endif

    @ViewBuilder private var rootContent: some View {
        // A real container keeps one presenter across the animated branch
        // change. Group distributes its modifiers to both outgoing and
        // incoming content, briefly giving each its own overlay window.
        ZStack {
            if isWorkspaceFlow {
                workspaceFlowContent
            } else {
                launchContent
            }
        }
    }

    @ViewBuilder private var workspaceFlowContent: some View {
        workspaceNavigationContent
            .sheet(isPresented: assistantPresented) {
                AssistantView(session: session)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }

    private var assistantPresented: Binding<Bool> {
        Binding(
            get: { coordinator.selectedSection == .assistant },
            set: { if !$0 { coordinator.selectedSection = .workspaces } }
        )
    }

    @ViewBuilder private var workspaceNavigationContent: some View {
        if sizeClass == .compact {
            // iPhone: standard NavigationStack with push/pop
            compactNavigationView
        } else {
            // iPad: NavigationSplitView with sidebar selection
            NavigationSplitView {
                WorkspaceListSidebar(
                    workspaceStore: session.workspaceStore,
                    isSearching: $isSearchingWorkspaces
                )
                .navigationSplitViewColumnWidth(
                    min: Constants.Root.sidebarMinimumWidth,
                    ideal: Constants.Root.sidebarIdealWidth,
                    max: Constants.Root.sidebarMaximumWidth
                )
            } detail: {
                detailContent
            }
            .navigationSplitViewStyle(.automatic)
            .modifier(WorkspaceActionLauncher(
                isSearching: isSearchingWorkspaces,
                alignment: .trailing,
                conversationBottomClearance: AssistantLaunchButton.scrollClearance,
                onCreateWorkspace: { if coordinator.canCreateWorkspace { showingCreateWorkspace = true } },
                onConnections: { showingConnections = true }
            ))
            .onChange(of: coordinator.shouldDismissWorkspaceCreation) { _, shouldDismiss in
                if shouldDismiss { showingCreateWorkspace = false }
            }
            .sheet(isPresented: $showingCreateWorkspace) {
                CreateWorkspaceView(session: session)
                    .environment(coordinator)
            }
            .sheet(isPresented: $showingConnections) {
                ConnectionsView()
                    .environment(coordinator)
            }
        }
    }

    private var launchContent: some View {
        ZStack {
            // One SplashArtView spans loading and connecting. Keeping
            // it in this stable position preserves animation playback across
            // the phase transition; the phase views render on top.
            if isLaunchSplash {
                SplashArtView()
            }
            switch coordinator.currentScreen {
            case .loading:
                LoadingView()
            case .pairing:
                PairingView()
            case .connecting:
                ConnectingView(networkStatus: networkAvailability.status)
            case .connectionFailed(let error):
                ConnectionFailureView(
                    errorMessage: error,
                    isCertMismatch: ConnectionFailureView.isCertificateMismatchMessage(error),
                    retryPolicy: coordinator.connectionFailureRetryPolicy,
                    networkStatus: networkAvailability.status
                )
            case .settings:
                SettingsView()
            case .disconnected:
                DisconnectedView()
            default:
                EmptyView()
            }
        }
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        rootContent
        .modifier(ConnectionSceneBackdrop())
        .animation(
            .easeInOut(duration: Constants.Root.screenAnimationDuration),
            value: String(describing: coordinator.currentScreen)
        )
        .overlay(alignment: .top) {
            // On multi-window platforms only the source backend's window
            // renders the toast (windowPresentsAlert); on iPhone every
            // toast renders as before. The tap still goes through the
            // manager's routing so delivery lands on the source backend's
            // registered handler.
            if let toast = notificationManager.currentToast,
               NotificationManager.windowPresentsAlert(
                   source: toast.sourceBackendID,
                   windowBackendID: session.backendID,
                   supportsMultipleWindows: supportsMultipleWindows
               ) {
                ToastView(
                    toast: toast,
                    onTap: {
                        notificationManager.dismissToast()
                        notificationManager.routeAgentSelection(
                            agentId: toast.agentId,
                            workspaceId: toast.workspaceId,
                            agentName: toast.agentName,
                            connectionId: toast.sourceBackendID.connectionID
                        )
                    },
                    onDismiss: {
                        notificationManager.dismissToast()
                    }
                )
                .padding(.top, Constants.Root.toastTopPadding)
            }
        }
        .overlay(alignment: .bottom) {
            // A live socket without its global subscription leaves every store
            // blind to updates; surface the bounded retry failure to the user.
            if case .failed = session.connection.globalSubscriptionState,
               session.connection.connectionState == .connected,
               !coordinator.isDisconnected {
                HStack(spacing: Constants.Root.reconnectButtonTopPadding) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Live updates unavailable")
                        .interFont(Constants.Typography.bodyXS)
                    Spacer(minLength: 0)
                    Button {
                        session.connection.retryGlobalSubscription()
                    } label: {
                        Text("Retry").interFont(Constants.Typography.bodyXS)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, Constants.Root.reconnectPanelSpacing)
                .padding(.vertical, Constants.Root.reconnectButtonTopPadding)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, Constants.Root.reconnectPanelSpacing)
                .padding(.bottom, Constants.Root.toastTopPadding)
                .accessibilityIdentifier("global-subscription-failed-banner")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background {
            // visionOS: notification sounds (agent-completion chime and
            // workspace attention cue) are emitted from within THIS window's
            // scene (not global system sounds) so spatial audio localizes
            // them to the source workspace's window. EmptyView on other
            // platforms, which keep the global sounds.
            windowFeedbackEmitter
        }
        .background {
            ConnectionLossPresenter(
                isPresented: coordinator.showsConnectionLossOverlay,
                mismatches: session.connection.certMismatches,
                networkStatus: networkAvailability.status,
                onHome: coordinator.onReturnToSavedMachines
            )
        }
        .safeAreaInset(edge: .bottom) {
            if isWorkspaceFlow, !coordinator.lifecycleState.hasEnteredRemoteUI,
               session.workspaceStore.lastUpdated == nil,
               ConnectionNetworkMessage(status: networkAvailability.status).isUnavailable {
                ConnectionNetworkStatusView(status: networkAvailability.status)
                    .padding()
            }
        }
        .task { await DemoConnectionLoss.run(connection: session.connection, coordinator: coordinator) }
        // intent://pair deep-link confirmation — presented over whichever
        // screen is current (first-run pairing or an existing connection).
        .sheet(item: $coordinator.pendingDeepLinkPairing) { request in
            DeepLinkPairingView(payload: request.payload)
        }
        .onAppear {
            let supportsMultipleWindows = supportsMultipleWindows
            let openWindow = openWindow
            notificationManager.supportsMultipleWindows = supportsMultipleWindows
            if supportsMultipleWindows {
                notificationManager.openBackendWindow = { openWindow(value: $0) }
            }
            // A pairing window (no backend) registers no handler: taps for
            // a backend route to that backend's own window instead.
            guard let backendID = session.backendID else { return }
            selectionHandlerToken = notificationManager.registerAgentSelectionHandler(
                for: backendID
            ) { [weak coordinator = coordinator] agentId, workspaceId, agentName, connectionId in
                if supportsMultipleWindows {
                    // Raise this backend's window before navigating it.
                    openWindow(value: backendID)
                }
                coordinator?.handleNotificationSelection(
                    agentId: agentId,
                    workspaceId: workspaceId,
                    agentName: agentName,
                    connectionId: connectionId
                )
            }
        }
        .onDisappear {
            guard let backendID = session.backendID,
                  let token = selectionHandlerToken else { return }
            notificationManager.removeAgentSelectionHandler(for: backendID, token: token)
        }
    }
}

struct ConversationDestinationView: View {
    struct Target: Equatable {
        let agentId: String
        let workspaceId: String
        let agentName: String
    }

    let fallback: Target?
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator

    private var target: Target? {
        if case let .agentConversation(agentId, workspaceId, agentName) = coordinator.currentScreen {
            return Target(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        }
        return fallback
    }

    var body: some View {
        if let target {
            ConversationView(
                agentId: target.agentId,
                workspaceId: target.workspaceId,
                agentName: target.agentName,
                session: session
            )
            .id(target.agentId)
        }
    }
}
