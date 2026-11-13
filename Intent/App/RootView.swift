import SwiftUI

struct RootView: View {
    @ScaledMetric(relativeTo: .body) private var warningIconSize: CGFloat = 17
    var networkAvailability: NetworkAvailability = .shared
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.workspaceUsesVerticalBar) var usesVerticalBar
    @Environment(\.colorScheme) var colorScheme
    // Multi-window tap routing (spec decision 5): false on iPhone, so alert
    // taps there always navigate in place — unchanged semantics.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @State private var notificationManager = NotificationManager.shared
    /// Token of this window's selection-handler registration, so disappear
    /// removes only this window's registration — never a successor's.
    @State private var selectionHandlerToken: UUID?
    @State private var sceneActivator = WindowSceneActivator()
    @State private var statusConsumer = UUID()
    @State private var statusWorkspaceId: String?
    @State private var isSearchingWorkspaces = false
    /// Regular width only; compact width's list owns its own value.
    @State private var workspacePresentation = WorkspaceChromePresentation.none
    @State private var conversationIsPopping = false
    /// Modal layers open in this window; keeps only the foremost chat's composer.
    @State private var composerCoverage = ComposerCoverage()
    @State private var readOnlyPillClearance = ReadOnlyPillClearance()
    @State private var connectionSwitcherOpen = false
    // Cross-file RootView navigation extensions bind or mutate this state, requiring internal access.
    @State var navigation = RootNavigationState() // swiftlint:disable:this private_swiftui_state
    // The unfolded Duo divides the window at its midpoint, including the trailing rail.
    @State private var duoSidebarWidth = Constants.Root.sidebarIdealWidth

    var conversationDestination: some View {
        ConversationDestinationView(
            fallback: navigation.conversationTarget,
            session: session
        )
        .background {
            if sizeClass == .regular {
                NavigationPopObserver(isPopping: $conversationIsPopping)
            }
        }
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
            if usesIPadShell, isWorkspaceFlow {
                IPadShellView(session: session)
            } else if isWorkspaceFlow || showsSettingsSheet {
                workspaceFlowContent
            } else {
                launchContent
            }
        }
        #if DEBUG
        .modifier(DemoIPadProducerEntry())
        .modifier(DemoToastOverlay())
        #endif
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
            if usesVerticalBar {
                compactNavigationView
                    .modifier(WorkspaceCompactActionLauncher(showsWorkspaceDetail: navigation.showingWorkspaceDetail))
            } else {
                compactNavigationView
            }
        } else {
            // iPad: NavigationSplitView with sidebar selection
            WorkspaceConnectionSwitcher(
                isPresented: $workspacePresentation.presenting(.switcher),
                isEnabled: isWorkspaceFlow && !workspacePresentation.isPresenting(.connections)
                    && !workspacePresentation.isPresenting(.createWorkspace)
                    && coordinator.selectedSection == .workspaces,
                onReveal: prepareConnectionSwitcher
            ) {
                workspaceSplitView
            }
            .modifier(WorkspaceActionLauncher(
                isSearching: isSearchingWorkspaces,
                alignment: .trailing,
                avoidsConversationInput: !conversationIsPopping,
                hostsVerticalBarButton: false,
                onCreateWorkspace: createWorkspace
            ) {
                workspacePresentation.setPresenting(.connections, true)
            })
            .onChange(of: coordinator.shouldDismissWorkspaceCreation) { _, shouldDismiss in
                if shouldDismiss { workspacePresentation.dismissWorkspaceCreation() }
            }
            .sheet(isPresented: $workspacePresentation.presenting(.createWorkspace)) {
                CreateWorkspaceView(session: session, coordinator: coordinator)
                    .environment(coordinator)
                    .coversConversationComposers()
            }
            .sheet(isPresented: $workspacePresentation.presenting(.connections)) {
                ConnectionsView()
                    .environment(coordinator)
                    .coversConversationComposers()
            }
        }
    }

    private var launchContent: some View {
        ZStack {
            // One SplashArtView spans loading and connecting. Keeping
            // it in this stable position preserves animation playback across
            // the phase transition; the phase views render on top.
            if isLaunchSplash {
                SplashArtView(style: coordinator.connectingStartedByLaunch ? .launch : .projectSwitch)
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
        // Per window, so a drop on one Mac never disables another window.
        .environment(\.isRemoteReadOnly, coordinator.isRemoteReadOnly)
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
                    Image(.attentionCircleFill)
                        .resizable()
                        .scaledToFit()
                        .frame(width: warningIconSize, height: warningIconSize)
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
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
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
            ConnectionLossLayers(
                coordinator: coordinator,
                connection: session.connection,
                networkStatus: networkAvailability.status
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
        .onChange(of: isWorkspaceFlow ? coordinator.selectedWorkspaceId : nil, initial: true) { _, workspaceId in
            updateWorkspaceStatusLease(workspaceId)
        }
        #if DEBUG
        .task { await DemoConnectionLoss.run(connection: session.connection, coordinator: coordinator) }
        .task { DemoInviteJoin.present(coordinator) }
        #endif
        // intent://pair and intent://invite confirmations — presented over
        // whichever screen is current (first-run pairing or a connection).
        .sheet(item: $coordinator.pendingDeepLink) { request in
            Group {
                switch request.target {
                case .pair(let payload): DeepLinkPairingView(payload: payload)
                case .invite(let link): InviteJoinView(link: link)
                }
            }
            .coversConversationComposers()
        }
        .onChange(of: usesIPadShell, initial: true) { _, enabled in
            coordinator.updateShellPresentation(enabled)
        }
        .onAppear {
            updateWorkspaceStatusLease(isWorkspaceFlow ? coordinator.selectedWorkspaceId : nil)
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
                for: backendID,
                coordinator.agentSelectionHandler(raising: supportsMultipleWindows ? sceneActivator : nil)
            )
        }
        .onDisappear {
            updateWorkspaceStatusLease(nil)
            guard let backendID = session.backendID,
                  let token = selectionHandlerToken else { return }
            notificationManager.removeAgentSelectionHandler(for: backendID, token: token)
        }
        .environment(composerCoverage)
        .environment(readOnlyPillClearance)
        .background { WindowSceneReader(activator: sceneActivator).frame(width: 0, height: 0) }
    }
}

extension RootView {
    static func presentsSettingsSheet(currentScreen: AppScreen, sizeClass: UserInterfaceSizeClass?) -> Bool {
        #if os(iOS)
        guard sizeClass == .compact else { return false }
        if case .settings = currentScreen { return true }
        #endif
        return false
    }
}

private extension RootView {
    func updateWorkspaceStatusLease(_ workspaceId: String?) {
        guard statusWorkspaceId != workspaceId else { return }
        if let workspaceId {
            session.retainWorkspaceStatus(workspaceId: workspaceId, consumer: statusConsumer)
        }
        if let previous = statusWorkspaceId {
            session.releaseWorkspaceStatus(workspaceId: previous, consumer: statusConsumer)
        }
        statusWorkspaceId = workspaceId
    }

    var usesIPadShell: Bool {
        #if os(iOS)
        IPadShellLayout.usesShell(isPad: UIDevice.current.userInterfaceIdiom == .pad, hasVerticalBar: usesVerticalBar, sizeClass: sizeClass)
        #else
        false
        #endif
    }

    var showsSettingsSheet: Bool {
        !usesIPadShell && Self.presentsSettingsSheet(currentScreen: coordinator.currentScreen, sizeClass: sizeClass)
    }

    var settingsPresented: Binding<Bool> {
        Binding(
            get: { showsSettingsSheet },
            set: { presented in
                if !presented, case .settings = coordinator.currentScreen {
                    coordinator.onSettingsBack()
                }
            }
        )
    }

    var agentHistoryEnabled: Bool {
        isWorkspaceFlow && !connectionSwitcherOpen && coordinator.selectedSection == .workspaces
    }

    @ViewBuilder var workspaceFlowContent: some View {
        AgentHistoryDrawer(isEnabled: agentHistoryEnabled) {
            workspaceNavigationContent
        }
        .onPreferenceChange(ConnectionSwitcherOpenPreference.self) { connectionSwitcherOpen = $0 }
        .sheet(isPresented: assistantPresented) {
            AssistantView(session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .coversConversationComposers()
        }
        .sheet(isPresented: settingsPresented) {
            SettingsView(presentedAsSheet: true, contentColorScheme: colorScheme)
                // The system status bar sits over the dark backdrop; content retains the selected theme.
                .preferredColorScheme(.dark)
                .presentationBackground(SettingsStyle.surface(for: colorScheme))
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(Constants.ConnectionSheet.cornerRadius)
                .coversConversationComposers()
        }
        .background {
            Color.clear.preference(
                key: ConnectionBackdropPreference.self,
                value: showsSettingsSheet ? ConnectionBackdropPreference.manualOpacity : 0
            )
        }
    }
}

private extension RootView {
    @ViewBuilder var workspaceSplitView: some View {
        if usesVerticalBar {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                WorkspaceListSidebar(
                    workspaceStore: session.workspaceStore,
                    isSearching: $isSearchingWorkspaces,
                    onCreateWorkspace: createWorkspace
                )
                .navigationSplitViewColumnWidth(duoSidebarWidth)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                detailContent
                    .modifier(WorkspaceActionLauncherToolbar(isEnabled: !isSearchingWorkspaces))
                    .toolbar(removing: .sidebarToggle)
            }
            .navigationSplitViewStyle(.balanced)
            .onGeometryChange(for: CGFloat.self) { geometry in
                // The content proposal excludes the system rail, but the fold does not.
                (geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing) / 2
                    - geometry.safeAreaInsets.leading
            } action: { duoSidebarWidth = $0 }
        } else {
            NavigationSplitView {
                WorkspaceListSidebar(
                    workspaceStore: session.workspaceStore,
                    isSearching: $isSearchingWorkspaces,
                    onCreateWorkspace: createWorkspace
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
        }
    }

    func prepareConnectionSwitcher() {
        isSearchingWorkspaces = false
    }

    func createWorkspace() {
        workspacePresentation.createWorkspace(canCreate: coordinator.canCreateWorkspace)
    }
}
