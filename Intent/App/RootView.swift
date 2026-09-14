import SwiftUI

struct RootView: View {
    private static let reconnectPanelMaximumWidth: CGFloat = 320

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
    /// share a single SplashArtView so GIF playback doesn't reset between them.
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
                                max: Constants.Root.sidebarMaximumWidth
                            )
                    } detail: {
                        detailContent
                    }
                    .navigationSplitViewStyle(.automatic)
                }
            } else {
                ZStack {
                    // One SplashArtView spans loading and connecting. Keeping
                    // it in this stable position preserves GIF playback across
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
                        ConnectingView()
                    case .connectionFailed(let error):
                        ConnectionFailureView(
                            errorMessage: error,
                            isCertMismatch: ConnectionFailureView.isCertificateMismatchMessage(error),
                            retryPolicy: coordinator.connectionFailureRetryPolicy
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
        .background {
            // visionOS: notification sounds (agent-completion chime and
            // workspace attention cue) are emitted from within THIS window's
            // scene (not global system sounds) so spatial audio localizes
            // them to the source workspace's window. EmptyView on other
            // platforms, which keep the global sounds.
            windowFeedbackEmitter
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
                                mismatches: session.connection.certMismatches
                            )
                                .frame(maxWidth: Self.reconnectPanelMaximumWidth)
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
                        cornerRadius: Constants.Root.reconnectPanelCornerRadius
                    ))
                }
                .transition(.opacity)
                .animation(
                    .easeInOut(duration: Constants.Root.screenAnimationDuration),
                    value: coordinator.isDisconnected
                )
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
            notificationManager.supportsMultipleWindows = supportsMultipleWindows
            if supportsMultipleWindows {
                notificationManager.openBackendWindow = { openWindow(value: $0) }
            }
            // A pairing window (no backend) registers no handler: taps for
            // a backend route to that backend's own window instead.
            guard let backendID = session.backendID else { return }
            selectionHandlerToken = notificationManager.registerAgentSelectionHandler(
                for: backendID
            ) { [weak coordinator] agentId, workspaceId, agentName, connectionId in
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
