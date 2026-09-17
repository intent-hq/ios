import SwiftUI

struct RootDetailContentView: View {
    let session: BackendSession
    let selectedWorkspaceId: String?
    let currentScreenDescription: String
    let conversationRequestId: Int
    let showingWorkspaceDetail: Bool
    let conversationFallback: RootNavigationPresentation.ConversationPayload?
    let colorScheme: ColorScheme
    @Binding var showingConversation: Bool
    @Binding var noteStack: NavigationPath
    let onSynchronize: () -> Void
    let onWorkspacePresentationChanged: (Bool) -> Void
    let onConversationPresentationChanged: (Bool) -> Void
    let onNoteStackChanged: (NavigationPath) -> Void
    let onOpenLinkedNote: (RootNavigationPresentation.NotePayload) -> Void

    var body: some View {
        if let workspaceId = selectedWorkspaceId {
            NavigationStack(path: $noteStack) {
                WorkspaceDetailView(workspaceId: workspaceId, session: session)
                    .navigationDestination(isPresented: $showingConversation) {
                        ConversationDestinationView(
                            fallback: conversationFallback,
                            session: session
                        )
                    }
                    .navigationDestination(for: NoteDestination.self) { dest in
                        NoteDetailView(
                            noteId: dest.noteId,
                            workspaceId: dest.workspaceId,
                            noteTitle: dest.noteTitle,
                            session: session
                        ) { noteId, workspaceId, title in
                            onOpenLinkedNote(RootNavigationPresentation.NotePayload(
                                noteId: noteId,
                                workspaceId: workspaceId,
                                noteTitle: title
                            ))
                        }
                    }
            }
            .onAppear {
                onSynchronize()
            }
            .onChange(of: currentScreenDescription) {
                onSynchronize()
            }
            .onChange(of: conversationRequestId) {
                onSynchronize()
            }
            .onChange(of: showingWorkspaceDetail) { _, newValue in
                onWorkspacePresentationChanged(newValue)
            }
            .onChange(of: showingConversation) { _, newValue in
                onConversationPresentationChanged(newValue)
            }
            .onChange(of: noteStack) { _, newStack in
                onNoteStackChanged(newStack)
            }
        } else {
            emptyDetailPlaceholder
        }
    }

    /// iPad split-view detail placeholder shown when no workspace is selected.
    var emptyDetailPlaceholder: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            ContentUnavailableView(
                "Select a Workspace",
                systemImage: "sidebar.left",
                description: Text("Choose a workspace from the sidebar to see its agents and notes.")
            )
        }
    }
}
