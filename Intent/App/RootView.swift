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
    @State private var navigationPresentation = RootNavigationPresentation()

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

    @ViewBuilder private var rootContent: some View {
        Group {
            if isWorkspaceFlow {
                workspaceFlowContent
            } else {
                launchContent
            }
        }
    }

    @ViewBuilder private var workspaceFlowContent: some View {
        if sizeClass == .compact {
            // iPhone: standard NavigationStack with push/pop
            RootCompactNavigationView(
                session: session,
                selectedWorkspaceId: coordinator.selectedWorkspaceId,
                currentScreenDescription: coordinator.currentScreenDescription,
                conversationRequestId: coordinator.conversationRequestId,
                conversationFallback: navigationPresentation.conversationFallback,
                notePayload: navigationPresentation.notePayload,
                showingWorkspaceDetail: $navigationPresentation.showingWorkspaceDetail,
                showingConversation: $navigationPresentation.showingConversation,
                showingNoteDetail: $navigationPresentation.showingNoteDetail,
                noteStack: $navigationPresentation.noteStack,
                onSynchronize: synchronizeNavigationPresentation,
                onWorkspacePresentationChanged: compactWorkspacePresentationChanged,
                onConversationPresentationChanged: compactConversationPresentationChanged,
                onNotePresentationChanged: notePresentationChanged,
                onOpenLinkedNote: openCompactLinkedNote
            )
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
                RootDetailContentView(
                    session: session,
                    selectedWorkspaceId: coordinator.selectedWorkspaceId,
                    currentScreenDescription: coordinator.currentScreenDescription,
                    conversationRequestId: coordinator.conversationRequestId,
                    showingWorkspaceDetail: navigationPresentation.showingWorkspaceDetail,
                    conversationFallback: navigationPresentation.conversationFallback,
                    colorScheme: colorScheme,
                    showingConversation: $navigationPresentation.showingConversation,
                    noteStack: $navigationPresentation.noteStack,
                    onSynchronize: synchronizeNavigationPresentation,
                    onWorkspacePresentationChanged: regularWorkspacePresentationChanged,
                    onConversationPresentationChanged: regularConversationPresentationChanged,
                    onNoteStackChanged: noteStackChanged,
                    onOpenLinkedNote: openRegularLinkedNote
                )
            }
            .navigationSplitViewStyle(.automatic)
        }
    }

    private var launchContent: some View {
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

    @ViewBuilder private var reconnectOverlay: some View {
        if coordinator.isDisconnected {
            ZStack {
                // Light tinted backdrop — lets blurred content show through
                Color.black.opacity(Constants.Root.reconnectBackdropOpacity)
                    .ignoresSafeArea()
                    .background(.ultraThinMaterial)
                reconnectPanel
            }
            .transition(.opacity)
            .animation(
                .easeInOut(duration: Constants.Root.screenAnimationDuration),
                value: coordinator.isDisconnected
            )
        }
    }

    private var reconnectPanel: some View {
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
                CertMismatchListView(mismatches: session.connection.certMismatches)
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

    var body: some View {
        @Bindable var coordinator = coordinator
        rootContent
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
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Button("Retry") {
                        session.connection.retryGlobalSubscription()
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
        .overlay {
            reconnectOverlay
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

private extension RootView {
    func synchronizeNavigationPresentation() {
        let effects = navigationPresentation.synchronize(
            with: coordinator.currentScreen,
            conversationRequestId: coordinator.conversationRequestId,
            isCompact: sizeClass == .compact,
            isRegularWidth: sizeClass == .regular
        )
        scheduleNavigationEffects(effects)
    }

    func compactWorkspacePresentationChanged(_ isPresented: Bool) {
        let change = navigationPresentation.compactWorkspacePresentationChanged(
            isPresented: isPresented,
            currentScreen: coordinator.currentScreen
        )
        scheduleNavigationEffects(change.deferredEffects)
        performCoordinatorAction(change.coordinatorAction)
    }

    func regularWorkspacePresentationChanged(_ isPresented: Bool) {
        scheduleNavigationEffects(
            navigationPresentation.regularWorkspacePresentationChanged(isPresented: isPresented)
        )
    }

    func compactConversationPresentationChanged(_ isPresented: Bool) {
        let action = navigationPresentation.conversationPresentationChanged(
            isPresented: isPresented,
            currentScreen: coordinator.currentScreen,
            suppressesProgrammaticDismissal: false
        )
        performCoordinatorAction(action)
    }

    func regularConversationPresentationChanged(_ isPresented: Bool) {
        let action = navigationPresentation.conversationPresentationChanged(
            isPresented: isPresented,
            currentScreen: coordinator.currentScreen,
            suppressesProgrammaticDismissal: true
        )
        performCoordinatorAction(action)
    }

    func notePresentationChanged(_ isPresented: Bool) {
        let action = navigationPresentation.notePresentationChanged(
            isPresented: isPresented,
            currentScreen: coordinator.currentScreen
        )
        performCoordinatorAction(action)
    }

    func noteStackChanged(_ newStack: NavigationPath) {
        let action = navigationPresentation.noteStackChanged(
            to: newStack,
            currentScreen: coordinator.currentScreen
        )
        performCoordinatorAction(action)
    }

    func openCompactLinkedNote(_ payload: RootNavigationPresentation.NotePayload) {
        navigationPresentation.openCompactLinkedNote(payload)
    }

    func openRegularLinkedNote(_ payload: RootNavigationPresentation.NotePayload) {
        navigationPresentation.openRegularLinkedNote(payload)
    }

    func scheduleNavigationEffects(_ effects: [RootNavigationPresentation.DeferredEffect]) {
        for effect in effects {
            DispatchQueue.main.async {
                navigationPresentation.applyDeferredEffect(
                    effect,
                    currentScreen: coordinator.currentScreen,
                    conversationRequestId: coordinator.conversationRequestId
                )
            }
        }
    }

    func performCoordinatorAction(_ action: RootNavigationPresentation.CoordinatorAction?) {
        switch action {
        case .backFromNote:
            coordinator.onBackFromNote()
        case .backToWorkspaceDetail:
            coordinator.onBackToWorkspaceDetail()
        case .backToWorkspaceList:
            coordinator.onBackToWorkspaceList()
        case nil:
            break
        }
    }
}

struct ConversationDestinationView: View {
    let fallback: RootNavigationPresentation.ConversationPayload?
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator

    private var target: RootNavigationPresentation.ConversationPayload? {
        Self.resolveTarget(currentScreen: coordinator.currentScreen, fallback: fallback)
    }

    static func resolveTarget(
        currentScreen: AppScreen,
        fallback: RootNavigationPresentation.ConversationPayload?
    ) -> RootNavigationPresentation.ConversationPayload? {
        if case let .agentConversation(agentId, workspaceId, agentName) = currentScreen {
            return RootNavigationPresentation.ConversationPayload(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName
            )
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
