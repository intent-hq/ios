import SwiftUI

extension RootView {
    @ViewBuilder
    var detailContent: some View {
        if let workspaceId = coordinator.selectedWorkspaceId {
            NavigationStack(path: $noteStack) {
                WorkspaceDetailView(
                    workspaceId: workspaceId,
                    session: session,
                    isSidebarVisible: usesVerticalBar
                )
                    .paneSwipe(isSwiping: .constant(false), onBack: nil, onForward: duoSwipeToFirstAgent(workspaceId: workspaceId))
                    .onPreferenceChange(WorkspaceFirstAgentPreference.self) { duoFirstAgent = $0 }
                    .navigationDestination(isPresented: $showingConversation) {
                        conversationDestination
                            .paneSwipe(isSwiping: .constant(false), onBack: duoSwipeBack(coordinator.onBackToWorkspaceDetail), onForward: nil)
                    }
                    .navigationDestination(for: NoteDestination.self) { dest in
                        NoteDetailView(
                            noteId: dest.noteId,
                            workspaceId: dest.workspaceId,
                            noteTitle: dest.noteTitle,
                            session: session
                        ) { noteId, workspaceId, title in
                            noteStack.append(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: title))
                        }
                        .paneSwipe(isSwiping: .constant(false), onBack: duoSwipeBack { if !noteStack.isEmpty { noteStack.removeLast() } }, onForward: nil)
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
            }
        } else {
            emptyDetailPlaceholder
        }
    }

    /// The unfolded Duo's detail column swipes like the iPad main pane; the stack still animates each step.
    func duoSwipeBack(_ action: @escaping () -> Void) -> (() -> Void)? {
        usesVerticalBar ? action : nil
    }

    func duoSwipeToFirstAgent(workspaceId: String) -> (() -> Void)? {
        guard usesVerticalBar, case .workspaceDetail = coordinator.currentScreen,
              let agent = duoFirstAgent, agent.workspaceId == workspaceId else { return nil }
        return { coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name) }
    }

    /// iPad split-view detail placeholder shown when no workspace is selected.
    var emptyDetailPlaceholder: some View {
        ZStack {
            WorkspaceDetailStyle.background(for: colorScheme).ignoresSafeArea()

            ContentUnavailableView {
                Label {
                    Text("Select a Workspace").interFont(Constants.Typography.bodyM.withFace(.semibold))
                } icon: {
                    Image(systemName: "sidebar.left")
                }
            } description: {
                Text("Choose a workspace from the sidebar to see its agents and notes.")
                    .interFont(Constants.Typography.bodyS)
            }
        }
    }
}
