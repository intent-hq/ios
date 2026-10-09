import SwiftUI

extension RootView {
    @ViewBuilder
    var compactNavigationView: some View {
        NavigationStack(path: $noteStack) {
            WorkspaceListView(workspaceStore: session.workspaceStore)
                .navigationDestination(isPresented: $showingWorkspaceDetail) {
                    if let workspaceId = coordinator.selectedWorkspaceId {
                        WorkspaceDetailView(workspaceId: workspaceId, session: session)
                            .modifier(WorkspaceActionLauncherToolbar())
                            #if os(iOS)
                            .toolbar(sizeClass == .compact && !usesVerticalBar ? .hidden : .visible, for: .navigationBar)
                            #else
                            .toolbar(.visible, for: .navigationBar)
                            #endif
                            .navigationDestination(isPresented: $showingConversation) {
                                conversationDestination
                                    .modifier(WorkspaceActionLauncherToolbar())
                            }
                            .navigationDestination(isPresented: $showingNoteDetail) {
                                NoteDetailView(
                                    noteId: noteDetailNoteId,
                                    workspaceId: noteDetailWorkspaceId,
                                    noteTitle: noteDetailNoteTitle,
                                    session: session
                                ) { noteId, workspaceId, title in
                                    noteDetailNoteId = noteId
                                    noteDetailWorkspaceId = workspaceId
                                    noteDetailNoteTitle = title
                                }
                                .id(noteDetailNoteId)
                                .modifier(WorkspaceActionLauncherToolbar())
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
        .onChange(of: coordinator.conversationRequestId) {
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

    func syncNavigationState() {
        switch coordinator.currentScreen {
        case let .agentConversation(agentId, workspaceId, agentName):
            syncAgentConversation(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        case let .noteDetail(noteId, workspaceId, noteTitle):
            syncNoteDetail(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
        case .workspaceDetail:
            syncWorkspaceDetail()
        default:
            resetNavigationState()
        }
    }

    private func syncAgentConversation(agentId: String, workspaceId: String, agentName: String) {
        let agentChanged = conversationAgentId != agentId
        let isNewRequest = handledConversationRequestId != coordinator.conversationRequestId
        handledConversationRequestId = coordinator.conversationRequestId
        conversationAgentId = agentId
        conversationWorkspaceId = workspaceId
        conversationAgentName = agentName
        if !noteStack.isEmpty { noteStack = NavigationPath() }
        if showingNoteDetail { showingNoteDetail = false }

        if !showingWorkspaceDetail {
            showingWorkspaceDetail = true
            pendingConversationPush = true
        } else if !showingConversation {
            if Self.canPushConversationNow(repushInFlight: programmaticConversationDismiss) {
                showingConversation = true
            }
        } else if Self.needsConversationRepush(
            agentChanged: agentChanged,
            isNewRequest: isNewRequest,
            isRegularWidth: sizeClass == .regular
        ) {
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
                if Self.shouldRepushConversation(
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
    }

    private func syncNoteDetail(noteId: String, workspaceId: String, noteTitle: String) {
        if sizeClass == .compact {
            // iPhone: use isPresented-based navigation (not noteStack)
            noteDetailNoteId = noteId
            noteDetailWorkspaceId = workspaceId
            noteDetailNoteTitle = noteTitle
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
            }
            let pendingNoteId = noteId
            let pendingWorkspaceId = workspaceId
            let pendingTitle = noteTitle
            DispatchQueue.main.async {
                if case .noteDetail(let curId, _, _) = coordinator.currentScreen, curId == pendingNoteId {
                    noteStack = NavigationPath()
                    noteStack.append(NoteDestination(
                        noteId: pendingNoteId,
                        workspaceId: pendingWorkspaceId,
                        noteTitle: pendingTitle
                    ))
                }
            }
        }
    }

    private func syncWorkspaceDetail() {
        if !showingWorkspaceDetail { showingWorkspaceDetail = true }
        if showingConversation { showingConversation = false }
        if showingNoteDetail { showingNoteDetail = false }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
    }

    private func resetNavigationState() {
        if showingWorkspaceDetail { showingWorkspaceDetail = false }
        if showingConversation { showingConversation = false }
        if showingNoteDetail { showingNoteDetail = false }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
    }

    static func needsConversationRepush(
        agentChanged: Bool,
        isNewRequest: Bool,
        isRegularWidth: Bool
    ) -> Bool {
        isRegularWidth && (agentChanged || isNewRequest)
    }

    static func canPushConversationNow(repushInFlight: Bool) -> Bool {
        !repushInFlight
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
