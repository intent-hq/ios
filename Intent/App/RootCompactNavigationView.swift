import SwiftUI

struct RootCompactNavigationView: View {
    let session: BackendSession
    let selectedWorkspaceId: String?
    let currentScreenDescription: String
    let conversationRequestId: Int
    let conversationFallback: RootNavigationPresentation.ConversationPayload?
    let notePayload: RootNavigationPresentation.NotePayload
    @Binding var showingWorkspaceDetail: Bool
    @Binding var showingConversation: Bool
    @Binding var showingNoteDetail: Bool
    @Binding var noteStack: NavigationPath
    let onSynchronize: () -> Void
    let onWorkspacePresentationChanged: (Bool) -> Void
    let onConversationPresentationChanged: (Bool) -> Void
    let onNotePresentationChanged: (Bool) -> Void
    let onOpenLinkedNote: (RootNavigationPresentation.NotePayload) -> Void

    var body: some View {
        NavigationStack(path: $noteStack) {
            WorkspaceListView(workspaceStore: session.workspaceStore)
                .navigationDestination(isPresented: $showingWorkspaceDetail) {
                    if let workspaceId = selectedWorkspaceId {
                        WorkspaceDetailView(workspaceId: workspaceId, session: session)
                            .navigationDestination(isPresented: $showingConversation) {
                                ConversationDestinationView(
                                    fallback: conversationFallback,
                                    session: session
                                )
                            }
                            .navigationDestination(isPresented: $showingNoteDetail) {
                                NoteDetailView(
                                    noteId: notePayload.noteId,
                                    workspaceId: notePayload.workspaceId,
                                    noteTitle: notePayload.noteTitle,
                                    session: session
                                ) { noteId, workspaceId, title in
                                    onOpenLinkedNote(RootNavigationPresentation.NotePayload(
                                        noteId: noteId,
                                        workspaceId: workspaceId,
                                        noteTitle: title
                                    ))
                                }
                                .id(notePayload.noteId)
                            }
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
        .onChange(of: showingNoteDetail) { _, newValue in
            onNotePresentationChanged(newValue)
        }
    }
}
