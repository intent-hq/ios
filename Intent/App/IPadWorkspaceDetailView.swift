import SwiftUI

/// The iPad routes directly within a stable pane; no split-view or size-class
/// dependent push/re-push is needed to replace the selected conversation.
struct IPadWorkspaceDetailView: View {
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var notePath = NavigationPath()

    var body: some View {
        NavigationStack(path: $notePath) {
            content
                .navigationDestination(for: NoteDestination.self) { destination in
                    note(destination, showsBackButton: true)
                }
        }
        .onChange(of: coordinator.currentScreenDescription) {
            if !notePath.isEmpty { notePath = NavigationPath() }
        }
        .onChange(of: coordinator.conversationRequestId) {
            if !notePath.isEmpty { notePath = NavigationPath() }
        }
        .task { await DemoFixtures.reselectConversationIfRequested(coordinator: coordinator) }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.currentScreen {
        case let .agentConversation(agentId, workspaceId, agentName):
            ConversationView(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                session: session,
                navigationRequestId: coordinator.conversationRequestId,
                onBack: coordinator.onBackToWorkspaceDetail
            )
            .id(agentId)
        case let .noteDetail(noteId, workspaceId, noteTitle):
            note(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle), showsBackButton: false)
                .id(noteId)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        IntentIconButton(icon: .arrowLeft, label: "Back to workspace", action: coordinator.onBackFromNote)
                    }
                    .intentToolbarSurface()
                }
        case let .workspaceDetail(workspaceId):
            WorkspaceDetailView(workspaceId: workspaceId, session: session)
        default:
            ContentUnavailableView {
                Label {
                    Text("Select a Workspace").interFont(Constants.Typography.bodyM.withFace(.semibold))
                } icon: {
                    Image(systemName: "sidebar.left")
                }
            } description: {
                Text("Choose a workspace from the sidebar to see its agents and notes.")
                    .interFont(Constants.Typography.bodyS)
            } actions: {
                Button("Show workspaces") { coordinator.onSelectIPadSection(.workspaces) }
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Constants.Conversation.Design.Palette.background(for: colorScheme))
        }
    }

    private func note(_ destination: NoteDestination, showsBackButton: Bool) -> some View {
        NoteDetailView(
            noteId: destination.noteId,
            workspaceId: destination.workspaceId,
            noteTitle: destination.noteTitle,
            session: session,
            showsBackButton: showsBackButton
        ) { noteId, workspaceId, title in
            notePath.append(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: title))
        }
    }
}
