import SwiftUI

extension RootView {
    @ViewBuilder
    var detailContent: some View {
        if let workspaceId = coordinator.selectedWorkspaceId {
            NavigationStack(path: $navigation.noteStack) {
                WorkspaceDetailView(
                    workspaceId: workspaceId,
                    session: session,
                    storesCache: coordinator.workspaceDetailStores,
                    isSidebarVisible: usesVerticalBar
                )
                    .pullRequestLinkRouting()
                    .navigationDestination(isPresented: $navigation.isShowingConversation) {
                        conversationDestination
                            .pullRequestLinkRouting()
                    }
                    .navigationDestination(for: NoteDestination.self) { dest in
                        NoteDetailView(
                            noteId: dest.noteId,
                            workspaceId: dest.workspaceId,
                            noteTitle: dest.noteTitle,
                            session: session
                        ) { noteId, workspaceId, title in
                            navigation.noteStack.append(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: title))
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
                if newValue, navigation.conversationPhase == .pendingAfterWorkspaceDetail {
                    DispatchQueue.main.async {
                        if navigation.conversationPhase == .pendingAfterWorkspaceDetail {
                            navigation.conversationPhase = .presented
                        }
                    }
                }
            }
            .onChange(of: navigation.conversationPhase) { oldPhase, newPhase in
                // Only user-initiated back transitions `.presented` -> `.hidden` while
                // `currentScreen` is `.agentConversation`; programmatic re-push uses `.repushing`.
                if oldPhase == .presented, newPhase == .hidden, case .agentConversation = coordinator.currentScreen {
                    coordinator.onBackToWorkspaceDetail()
                }
            }
            .onChange(of: navigation.noteStack) { _, newStack in
                if newStack.isEmpty, case .noteDetail = coordinator.currentScreen {
                    coordinator.onBackFromNote()
                }
            }
        } else {
            emptyDetailPlaceholder
        }
    }

    /// iPad split-view detail placeholder shown when no workspace is selected.
    var emptyDetailPlaceholder: some View {
        ZStack {
            WorkspaceDetailStyle.background(for: colorScheme).ignoresSafeArea()
            WorkspaceDetailPlaceholder()
        }
    }
}

/// Detail-pane empty state for wide layouts with no workspace selected (#908).
struct WorkspaceDetailPlaceholder: View {
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 48

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Select a Workspace").interFont(Constants.Typography.bodyM.withFace(.semibold))
            } icon: {
                Image(.collapseLeft)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            }
        } description: {
            Text("Choose a workspace from the sidebar, or create one, to see its agents and notes.")
                .interFont(Constants.Typography.bodyS)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace.detail.placeholder")
    }
}
