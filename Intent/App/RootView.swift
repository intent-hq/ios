import SwiftUI

struct RootView: View {
    @ScaledMetric(relativeTo: .body) private var warningIconSize: CGFloat = 17
    var networkAvailability: NetworkAvailability = .shared
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.workspaceUsesVerticalBar) var usesVerticalBar
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @State private var notificationManager = NotificationManager.shared
    @State private var selectionHandlerToken: UUID?
    @State private var sceneActivator = WindowSceneActivator()
    @State private var statusConsumer = UUID()
    @State private var statusWorkspaceId: String?
    @State private var isSearchingWorkspaces = false
    @State private var workspacePresentation = WorkspaceChromePresentation.none
    @State private var conversationIsPopping = false
    @State private var composerCoverage = ComposerCoverage()
    @State private var readOnlyPillClearance = ReadOnlyPillClearance()
    @State private var connectionSwitcherOpen = false
    @State var navigation = RootNavigationState() // swiftlint:disable:this private_swiftui_state
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

    private var isLaunchSplash: Bool {
        switch coordinator.currentScreen {
        case .loading, .connecting:
            return true
        default:
            return false
        }
    }

    @ViewBuilder private var windowFeedbackEmitter: some View {
        #if os(visionOS)
        WindowFeedbackSoundEmitter(eventID: feedbackEventForThisWindow?.id)
        WindowFeedbackSoundEmitter(eventID: session.attentionCueCenter.windowCueEvent?.id)
        #endif
    }

    #if os(visionOS)
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
        ZStack {
            if usesIPadShell, isWorkspaceFlow {
                IPadShellView(session: session)
            } else if isWorkspaceFlow || showsSettingsSheet {
                workspaceFlowContent
            } else {
                launchContent
            }
        }
        .modifier(NativeBrowserPresenter())
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
            if usesVerticalBar {
                compactNavigationView
                    .modifier(WorkspaceCompactActionLauncher(showsWorkspaceDetail: navigation.showingWorkspaceDetail))
            } else {
                compactNavigationView
            }
        } else {
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
        .environment(\.isRemoteReadOnly, coordinator.isRemoteReadOnly)
        .modifier(ConnectionSceneBackdrop())
        .animation(
            .easeInOut(duration: Constants.Root.screenAnimationDuration),
            value: String(describing: coordinator.currentScreen)
        )
        .overlay(alignment: .top) {
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
