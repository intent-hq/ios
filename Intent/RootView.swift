import SwiftUI

struct NoteDestination: Hashable {
    let id: UUID
    let noteId: String
    let workspaceId: String
    let noteTitle: String

    init(noteId: String, workspaceId: String, noteTitle: String) {
        self.id = UUID()
        self.noteId = noteId
        self.workspaceId = workspaceId
        self.noteTitle = noteTitle
    }

    static func == (lhs: NoteDestination, rhs: NoteDestination) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct AgentDestination: Hashable, Identifiable {
    let id: UUID
    let agentId: String
    let workspaceId: String
    let agentName: String

    init(agentId: String, workspaceId: String, agentName: String) {
        self.id = UUID()
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName
    }

    static func == (lhs: AgentDestination, rhs: AgentDestination) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct RootView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(ConnectionManager.self) var connectionManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var notificationManager = NotificationManager.shared
    @State private var showingWorkspaceDetail = false
    @State private var showingConversation = false
    @State private var conversationAgentId: String = ""
    @State private var conversationWorkspaceId: String = ""
    @State private var conversationAgentName: String = ""
    // Compact (iPhone) note detail navigation — uses isPresented instead of noteStack
    @State private var showingNoteDetail = false
    @State private var noteDetailNoteId: String = ""
    @State private var noteDetailWorkspaceId: String = ""
    @State private var noteDetailNoteTitle: String = ""
    @State private var pendingConversationPush = false
    @State private var pendingNoteDetailPush = false
    /// True while syncNavigationState() tears down the conversation for the iPad
    /// re-push dance, so the user-back onChange handler doesn't misfire.
    @State private var programmaticConversationDismiss = false
    @State private var noteStack = NavigationPath()
    /// Parallel array tracking note titles pushed onto noteStack for iPad back-button labels.
    @State private var stackTitles: [String] = []

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
                        WorkspaceListSidebar()
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
                        coordinator.onSelectAgent(
                            toast.agentId,
                            workspaceId: toast.workspaceId,
                            agentName: toast.agentName
                        )
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
                        if !connectionManager.certMismatches.isEmpty {
                            CertMismatchListView(mismatches: connectionManager.certMismatches)
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
    }

    @ViewBuilder
    private var compactNavigationView: some View {
        NavigationStack(path: $noteStack) {
            WorkspaceListView()
                .navigationDestination(isPresented: $showingWorkspaceDetail) {
                    if let workspaceId = coordinator.selectedWorkspaceId {
                        WorkspaceDetailView(workspaceId: workspaceId)
                            .navigationDestination(isPresented: $showingConversation) {
                                ConversationView(
                                    agentId: conversationAgentId,
                                    workspaceId: conversationWorkspaceId,
                                    agentName: conversationAgentName
                                )
                                .id(conversationAgentId)
                            }
                            .navigationDestination(isPresented: $showingNoteDetail) {
                                NoteDetailView(
                                    noteId: noteDetailNoteId,
                                    workspaceId: noteDetailWorkspaceId,
                                    noteTitle: noteDetailNoteTitle,
                                    onNavigateToNote: { noteId, wsId, title in
                                        noteDetailNoteId = noteId
                                        noteDetailWorkspaceId = wsId
                                        noteDetailNoteTitle = title
                                    }
                                )
                                .id(noteDetailNoteId)
                            }
                    }
                }
        }
        .onAppear {
            syncNavigationState()
        }
        .onChange(of: coordinator.currentScreenDescription) {
            syncNavigationState()
        }
        .onChange(of: showingWorkspaceDetail) { _, newValue in
            if newValue {
                if pendingConversationPush {
                    DispatchQueue.main.async {
                        showingConversation = true
                        pendingConversationPush = false
                    }
                }
                if pendingNoteDetailPush {
                    DispatchQueue.main.async {
                        showingNoteDetail = true
                        pendingNoteDetailPush = false
                    }
                }
            }
            if !newValue, case .workspaceDetail = coordinator.currentScreen {
                coordinator.onBackToWorkspaceList()
            }
            if !newValue, case .agentConversation = coordinator.currentScreen {
                coordinator.onBackToWorkspaceList()
            }
            if !newValue, case .noteDetail = coordinator.currentScreen {
                coordinator.onBackToWorkspaceList()
            }
        }
        .onChange(of: showingConversation) { _, newValue in
            if !newValue, case .agentConversation = coordinator.currentScreen {
                coordinator.onBackToWorkspaceDetail()
            }
        }
        .onChange(of: showingNoteDetail) { _, newValue in
            if !newValue, case .noteDetail = coordinator.currentScreen {
                coordinator.onBackFromNote()
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let workspaceId = coordinator.selectedWorkspaceId {
            NavigationStack(path: $noteStack) {
                WorkspaceDetailView(workspaceId: workspaceId)
                    .navigationDestination(isPresented: $showingConversation) {
                        ConversationView(
                            agentId: conversationAgentId,
                            workspaceId: conversationWorkspaceId,
                            agentName: conversationAgentName
                        )
                        .id(conversationAgentId)
                        .navigationBarBackButtonHidden(sizeClass == .regular)
                        .toolbar {
                            if sizeClass == .regular {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button {
                                        // Pop directly so the back action works even if the
                                        // coordinator is already on .workspaceDetail (no
                                        // reliance on a screen-description change alone).
                                        showingConversation = false
                                        coordinator.onBackToWorkspaceDetail()
                                    } label: {
                                        HStack(spacing: Constants.Root.backButtonSpacing) {
                                            Image(systemName: "chevron.left")
                                            Text("Agents")
                                        }
                                        .font(.body)
                                    }
                                }
                            }
                        }
                    }
                    .navigationDestination(for: NoteDestination.self) { dest in
                        NoteDetailView(
                            noteId: dest.noteId,
                            workspaceId: dest.workspaceId,
                            noteTitle: dest.noteTitle,
                            onNavigateToNote: { noteId, wsId, title in
                                noteStack.append(NoteDestination(noteId: noteId, workspaceId: wsId, noteTitle: title))
                                stackTitles.append(title)
                            }
                        )
                        .navigationBarBackButtonHidden(sizeClass == .regular)
                        .toolbar {
                            if sizeClass == .regular {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button {
                                        noteStack.removeLast()
                                    } label: {
                                        HStack(spacing: Constants.Root.backButtonSpacing) {
                                            Image(systemName: "chevron.left")
                                            Text(stackBackTitle())
                                        }
                                        .font(.body)
                                    }
                                }
                            }
                        }
                    }
            }
            .onAppear {
                syncNavigationState()
            }
            .onChange(of: coordinator.currentScreenDescription) {
                syncNavigationState()
            }
            .onChange(of: showingWorkspaceDetail) { _, newValue in
                if newValue {
                    if pendingConversationPush {
                        DispatchQueue.main.async {
                            showingConversation = true
                            pendingConversationPush = false
                        }
                    }
                }
            }
            .onChange(of: showingConversation) { _, newValue in
                // When user taps the back button, sync coordinator. Skip when the
                // dismissal is the programmatic iPad tear-down/re-push, which is
                // not a user-initiated back navigation. Consume the flag here so
                // it only ever suppresses the single tear-down dismissal; the
                // deferred re-push block clears it again as a backstop.
                if !newValue, programmaticConversationDismiss {
                    programmaticConversationDismiss = false
                    return
                }
                if !newValue, case .agentConversation = coordinator.currentScreen {
                    coordinator.onBackToWorkspaceDetail()
                }
            }
            .onChange(of: noteStack) { _, newStack in
                if newStack.isEmpty, case .noteDetail = coordinator.currentScreen {
                    coordinator.onBackFromNote()
                }
                // Keep stackTitles in sync when items are popped
                if stackTitles.count > newStack.count {
                    stackTitles = Array(stackTitles.prefix(newStack.count))
                }
            }
        } else {
            emptyDetailPlaceholder
        }
    }

    /// iPad split-view detail placeholder shown when no workspace is selected.
    private var emptyDetailPlaceholder: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            VStack(spacing: Constants.Root.emptyStateSpacing) {
                Image(systemName: "sidebar.left")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Text("Select a workspace")
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text("Choose a workspace from the sidebar to see its agents and notes.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Constants.Root.emptyStateHorizontalPadding)
            }
        }
    }

    /// Compute the back button title using the parallel stackTitles array.
    /// Shows the previous item's title, or "Context" if this is the first item.
    private func stackBackTitle() -> String {
        if stackTitles.count >= 2 {
            return stackTitles[stackTitles.count - 2]
        }
        return "Context"
    }

    private func syncNavigationState() {
        if case .agentConversation(let agentId, let workspaceId, let agentName) = coordinator.currentScreen {
            let agentChanged = conversationAgentId != agentId
            conversationAgentId = agentId
            conversationWorkspaceId = workspaceId
            conversationAgentName = agentName
            if !noteStack.isEmpty { noteStack = NavigationPath(); stackTitles.removeAll() }
            if showingNoteDetail { showingNoteDetail = false }

            if !showingWorkspaceDetail {
                showingWorkspaceDetail = true
                pendingConversationPush = true
            } else if !showingConversation {
                showingConversation = true
            } else if agentChanged && sizeClass == .regular {
                // iPad NavigationStack rebuild race: when the workspace detail is
                // rebuilt (different workspace) but showingConversation is still
                // true, SwiftUI may not push the new conversation. Tear down
                // first, then re-push on the next runloop tick so the rebuilt
                // NavigationStack accepts the new destination.
                programmaticConversationDismiss = true
                showingConversation = false
                let pendingAgentId = agentId
                // Ordering note: the onChange(of: showingConversation) pass for the
                // tear-down above runs in the current runloop's view update, before
                // this next-tick block, so the flag is normally consumed there and
                // the clear below is just a backstop.
                DispatchQueue.main.async {
                    programmaticConversationDismiss = false
                    if RootView.shouldRepushConversation(
                        currentScreen: coordinator.currentScreen,
                        pendingAgentId: pendingAgentId,
                        conversationAgentId: conversationAgentId
                    ) {
                        showingConversation = true
                    }
                }
            }
            // If showingConversation is already true and agent changed,
            // the .id(conversationAgentId) modifier forces SwiftUI to
            // destroy and recreate ConversationView with fresh @State-owned state
        } else if case .noteDetail(let nId, let wId, let nTitle) = coordinator.currentScreen {
            if sizeClass == .compact {
                // iPhone: use isPresented-based navigation (not noteStack)
                noteDetailNoteId = nId
                noteDetailWorkspaceId = wId
                noteDetailNoteTitle = nTitle
                if showingConversation { showingConversation = false }
                if !showingWorkspaceDetail {
                    showingWorkspaceDetail = true
                    pendingNoteDetailPush = true
                } else if !showingNoteDetail {
                    showingNoteDetail = true
                }
            } else {
                // iPad: use noteStack path-based navigation
                if showingConversation { showingConversation = false }
                if !showingWorkspaceDetail {
                    showingWorkspaceDetail = true
                }
                // Tear down then rebuild on next runloop tick so a freshly
                // rebuilt NavigationStack (e.g. after workspace switch) picks
                // up the new destination reliably.
                if !noteStack.isEmpty {
                    noteStack = NavigationPath()
                    stackTitles.removeAll()
                }
                let pendingNoteId = nId
                let pendingWorkspaceId = wId
                let pendingTitle = nTitle
                DispatchQueue.main.async {
                    if case .noteDetail(let curId, _, _) = coordinator.currentScreen, curId == pendingNoteId {
                        noteStack = NavigationPath()
                        noteStack.append(NoteDestination(noteId: pendingNoteId, workspaceId: pendingWorkspaceId, noteTitle: pendingTitle))
                        stackTitles = [pendingTitle]
                    }
                }
            }
        } else if case .workspaceDetail = coordinator.currentScreen {
            if !showingWorkspaceDetail { showingWorkspaceDetail = true }
            if showingConversation { showingConversation = false }
            if showingNoteDetail { showingNoteDetail = false }
            if !noteStack.isEmpty { noteStack = NavigationPath(); stackTitles.removeAll() }
        } else {
            if showingWorkspaceDetail { showingWorkspaceDetail = false }
            if showingConversation { showingConversation = false }
            if showingNoteDetail { showingNoteDetail = false }
            if !noteStack.isEmpty { noteStack = NavigationPath(); stackTitles.removeAll() }
        }
    }

    /// Guard for the deferred iPad conversation re-push scheduled by the
    /// tear-down/re-push branch in `syncNavigationState()`. Only re-push when
    /// the coordinator is still showing the same conversation; if the user has
    /// navigated back in the meantime, the re-push must be dropped.
    /// The screen match compares agent ids only, which assumes agent ids are
    /// globally unique across workspaces (`agent-{uuid}`).
    static func shouldRepushConversation(
        currentScreen: AppScreen,
        pendingAgentId: String,
        conversationAgentId: String
    ) -> Bool {
        guard conversationAgentId == pendingAgentId else { return false }
        if case .agentConversation(let agentId, _, _) = currentScreen, agentId == pendingAgentId {
            return true
        }
        return false
    }
}

