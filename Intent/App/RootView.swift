import SwiftUI

struct RootView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.colorScheme) var colorScheme
    // Multi-window tap routing (spec decision 5): false on iPhone, so alert
    // taps there always navigate in place — unchanged semantics.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    @State private var notificationManager = NotificationManager.shared
    @State var showingWorkspaceDetail = false
    @State var showingConversation = false
    @State var conversationAgentId: String = ""
    @State var conversationWorkspaceId: String = ""
    @State var conversationAgentName: String = ""
    // Compact (iPhone) note detail navigation — uses isPresented instead of noteStack
    @State var showingNoteDetail = false
    @State var noteDetailNoteId: String = ""
    @State var noteDetailWorkspaceId: String = ""
    @State var noteDetailNoteTitle: String = ""
    @State var pendingConversationPush = false
    @State var pendingNoteDetailPush = false
    /// True while syncNavigationState() tears down the conversation for the iPad
    /// re-push dance, so the user-back onChange handler doesn't misfire.
    @State var programmaticConversationDismiss = false
    @State var noteStack = NavigationPath()

    private var isWorkspaceFlow: Bool {
        switch coordinator.currentScreen {
        case .workspaceList, .workspaceDetail, .agentConversation, .noteDetail:
            return true
        default:
            return false
        }
    }

    /// True during the launch splash phases (loading and connecting), which
    /// share a single SplashArtView so the art doesn't reset between them.
    private var isLaunchSplash: Bool {
        switch coordinator.currentScreen {
        case .loading, .connecting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        Group {
            if isWorkspaceFlow {
                if sizeClass == .compact {
                    // iPhone: standard NavigationStack with push/pop
                    compactNavigationView
                } else {
                    // iPad: NavigationSplitView with sidebar selection
                    NavigationSplitView {
                        WorkspaceListSidebar(workspaceStore: session.workspaceStore)
                            .navigationSplitViewColumnWidth(
                                min: Constants.Root.sidebarMinimumWidth,
                                ideal: Constants.Root.sidebarIdealWidth,
                                max: Constants.Root.sidebarMaximumWidth)
                    } detail: {
                        detailContent
                    }
                    .navigationSplitViewStyle(.automatic)
                }
            } else {
                ZStack {
                    // One SplashArtView spans the loading and connecting
                    // phases: keeping it in this stable position preserves
                    // its seed and reveal state across the transition, so the
                    // art doesn't visibly reset. LoadingView/ConnectingView
                    // render only their phase logic on top of it.
                    if isLaunchSplash {
                        SplashArtView()
                    }
                    switch coordinator.currentScreen {
                    case .loading:
                        LoadingView()
                    case .pairing:
                        PairingView()
                    case .connecting:
                        ConnectingView()
                    case .connectionFailed(let error):
                        ConnectionFailureView(
                            errorMessage: error,
                            isCertMismatch: ConnectionFailureView.isCertificateMismatchMessage(error)
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
        }
        .animation(.easeInOut(duration: Constants.Root.screenAnimationDuration),
                   value: String(describing: coordinator.currentScreen))
        .overlay(alignment: .top) {
            if let toast = notificationManager.currentToast {
                ToastView(
                    toast: toast,
                    onTap: {
                        notificationManager.dismissToast()
                        switch NotificationManager.tapRoute(
                            sourceBackendID: toast.sourceBackendID,
                            windowBackendID: coordinator.backendID,
                            supportsMultipleWindows: supportsMultipleWindows)
                        {
                        case .openPinnedWindow(let target):
                            openWindow(value: target)
                        case .navigateInCurrentWindow:
                            coordinator.onSelectAgent(
                                toast.agentId,
                                workspaceId: toast.workspaceId,
                                agentName: toast.agentName
                            )
                        }
                    },
                    onDismiss: {
                        notificationManager.dismissToast()
                    }
                )
                .padding(.top, Constants.Root.toastTopPadding)
            }
        }
        .overlay {
            if coordinator.isDisconnected {
                ZStack {
                    // Light tinted backdrop — lets blurred content show through
                    Color.black.opacity(Constants.Root.reconnectBackdropOpacity)
                        .ignoresSafeArea()
                        .background(.ultraThinMaterial)

                    VStack(spacing: Constants.Root.reconnectPanelSpacing) {
                        ProgressView()
                            .scaleEffect(Constants.Root.reconnectProgressScale)
                            .tint(.primary)

                        Text("Reconnecting...")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text("Connection to desktop app was lost")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        // Passive per-host cert-mismatch list: hosts that
                        // presented a wrong certificate during the reconnect
                        // race, while retries continue on the remaining hosts.
                        if !session.connection.certMismatches.isEmpty {
                            CertMismatchListView(
                                mismatches: session.connection.certMismatches)
                                .frame(maxWidth: 320)
                        }

                        Button("Log Off") {
                            coordinator.onLogOff()
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .padding(.top, Constants.Root.reconnectButtonTopPadding)
                    }
                    .padding(Constants.Root.reconnectPanelPadding)
                    .background(.regularMaterial, in: RoundedRectangle(
                        cornerRadius: Constants.Root.reconnectPanelCornerRadius))
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: Constants.Root.screenAnimationDuration),
                           value: coordinator.isDisconnected)
            }
        }
        // intent://pair deep-link confirmation — presented over whichever
        // screen is current (first-run pairing or an existing connection).
        .sheet(item: $coordinator.pendingDeepLinkPairing) { request in
            DeepLinkPairingView(payload: request.payload)
        }
        .onAppear {
            let supportsMultipleWindows = supportsMultipleWindows
            let openWindow = openWindow
            notificationManager.setAgentSelectionHandler {
                [weak coordinator] agentId, workspaceId, agentName, connectionId in
                let source = NotificationManager.sourceBackendID(
                    connectionId: connectionId,
                    activeConnectionId: PersistenceManager.shared.activeConnection()?.id)
                switch NotificationManager.tapRoute(
                    sourceBackendID: source,
                    windowBackendID: coordinator?.backendID,
                    supportsMultipleWindows: supportsMultipleWindows)
                {
                case .openPinnedWindow(let target):
                    openWindow(value: target)
                case .navigateInCurrentWindow:
                    coordinator?.handleNotificationSelection(
                        agentId: agentId,
                        workspaceId: workspaceId,
                        agentName: agentName,
                        connectionId: connectionId
                    )
                }
            }
        }
    }
}
