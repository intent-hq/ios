import SwiftUI

extension RootView {
    @ViewBuilder
    var compactNavigationView: some View {
        NavigationStack(path: $navigation.noteStack) {
            WorkspaceListView(workspaceStore: session.workspaceStore)
                .navigationDestination(isPresented: $navigation.showingWorkspaceDetail) {
                    if let workspaceId = coordinator.selectedWorkspaceId {
                        WorkspaceDetailView(workspaceId: workspaceId, session: session, storesCache: coordinator.workspaceDetailStores)
                            .pullRequestLinkRouting()
                            .modifier(WorkspaceActionLauncherToolbar())
                            #if os(iOS)
                            .toolbar(sizeClass == .compact && !usesVerticalBar ? .hidden : .visible, for: .navigationBar)
                            #else
                            .toolbar(.visible, for: .navigationBar)
                            #endif
                            .navigationDestination(isPresented: $navigation.isShowingConversation) {
                                conversationDestination
                                    .pullRequestLinkRouting()
                                    .modifier(WorkspaceActionLauncherToolbar())
                            }
                            .navigationDestination(isPresented: $navigation.isShowingCompactNoteDetail) {
                                compactNoteDetail
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
        .onChange(of: navigation.showingWorkspaceDetail) { _, newValue in
            if newValue {
                if navigation.conversationPhase == .pendingAfterWorkspaceDetail {
                    DispatchQueue.main.async {
                        if navigation.conversationPhase == .pendingAfterWorkspaceDetail {
                            navigation.conversationPhase = .presented
                        }
                    }
                }
                if navigation.compactNotePhase == .pendingAfterWorkspaceDetail {
                    DispatchQueue.main.async {
                        if navigation.compactNotePhase == .pendingAfterWorkspaceDetail {
                            navigation.compactNotePhase = .presented
                        }
                    }
                }
            } else {
                switch coordinator.currentScreen {
                case .workspaceDetail, .agentConversation, .noteDetail:
                    coordinator.onBackToWorkspaceList()
                default:
                    break
                }
            }
        }
        .onChange(of: navigation.conversationPhase) { oldPhase, newPhase in
            if oldPhase == .presented, newPhase == .hidden, case .agentConversation = coordinator.currentScreen {
                coordinator.onBackToWorkspaceDetail()
            }
        }
        .onChange(of: navigation.compactNotePhase) { oldPhase, newPhase in
            if oldPhase == .presented, newPhase == .hidden, case .noteDetail = coordinator.currentScreen {
                coordinator.onBackFromNote()
            }
        }
    }

    private var compactNoteDetail: some View {
        let target = navigation.compactNoteTarget ?? NoteDestination(noteId: "", workspaceId: "", noteTitle: "")
        return NoteDetailView(
            noteId: target.noteId,
            workspaceId: target.workspaceId,
            noteTitle: target.noteTitle,
            session: session
        ) { noteId, workspaceId, title in
            navigation.compactNoteTarget = NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: title)
        }
        .id(target.noteId)
        .pullRequestLinkRouting()
        .modifier(WorkspaceActionLauncherToolbar())
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
            navigation.reset()
        }
    }

    private func syncAgentConversation(agentId: String, workspaceId: String, agentName: String) {
        let agentChanged = navigation.conversationTarget?.agentId != agentId
        let isNewRequest = navigation.handledConversationRequestId != coordinator.conversationRequestId
        navigation.handledConversationRequestId = coordinator.conversationRequestId
        navigation.conversationTarget = ConversationDestinationView.Target(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName
        )
        navigation.clearNotes()

        if !navigation.showingWorkspaceDetail {
            navigation.showingWorkspaceDetail = true
            navigation.conversationPhase = .pendingAfterWorkspaceDetail
        } else if !navigation.isShowingConversation {
            if Self.canPushConversationNow(repushInFlight: navigation.isRepushingConversation) {
                navigation.conversationPhase = .presented
            }
        } else if Self.needsConversationRepush(
            agentChanged: agentChanged,
            isNewRequest: isNewRequest,
            isRegularWidth: sizeClass == .regular
        ) {
            // iPad NavigationStack rebuild race: when the workspace detail is
            // rebuilt (different workspace) while presented, tear down first,
            // then re-push on the next runloop tick so the rebuilt stack
            // accepts the new destination without misfiring user-back handlers.
            navigation.conversationPhase = .repushing
            let pendingAgentId = agentId
            DispatchQueue.main.async {
                if Self.shouldRepushConversation(
                    currentScreen: coordinator.currentScreen,
                    pendingAgentId: pendingAgentId,
                    conversationAgentId: navigation.conversationTarget?.agentId ?? ""
                ) {
                    navigation.conversationPhase = .presented
                } else if navigation.conversationPhase == .repushing {
                    navigation.conversationPhase = .hidden
                }
            }
        }
    }

    private func syncNoteDetail(noteId: String, workspaceId: String, noteTitle: String) {
        navigation.hideConversation()
        if sizeClass == .compact {
            navigation.compactNoteTarget = NoteDestination(
                noteId: noteId,
                workspaceId: workspaceId,
                noteTitle: noteTitle
            )
            if !navigation.showingWorkspaceDetail {
                navigation.showingWorkspaceDetail = true
                navigation.compactNotePhase = .pendingAfterWorkspaceDetail
            } else if !navigation.isShowingCompactNoteDetail {
                navigation.compactNotePhase = .presented
            }
        } else {
            if !navigation.showingWorkspaceDetail {
                navigation.showingWorkspaceDetail = true
            }
            if !navigation.noteStack.isEmpty {
                navigation.noteStack = NavigationPath()
            }
            let pendingNoteId = noteId
            let pendingWorkspaceId = workspaceId
            let pendingTitle = noteTitle
            DispatchQueue.main.async {
                if case .noteDetail(let curId, _, _) = coordinator.currentScreen, curId == pendingNoteId {
                    navigation.noteStack = NavigationPath()
                    navigation.noteStack.append(NoteDestination(
                        noteId: pendingNoteId,
                        workspaceId: pendingWorkspaceId,
                        noteTitle: pendingTitle
                    ))
                }
            }
        }
    }

    private func syncWorkspaceDetail() {
        if !navigation.showingWorkspaceDetail { navigation.showingWorkspaceDetail = true }
        navigation.hideConversation()
        navigation.clearNotes()
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
