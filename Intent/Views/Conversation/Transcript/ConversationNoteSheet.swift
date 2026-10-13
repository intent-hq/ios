import SwiftUI

/// Note sheet opened from a transcript note reference. Note-to-note links that
/// target the hidden global Assistant workspace push inside the sheet: that
/// workspace has no place in the Workspaces tab, so the coordinator route would
/// replace the user's open workspace screen with it. Other links keep the
/// coordinator route.
struct ConversationNoteSheet: View {
    let noteInfo: NoteSheetInfo
    let session: BackendSession
    let onDone: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            noteDetail(noteId: noteInfo.noteId, workspaceId: noteInfo.workspaceId, noteTitle: noteInfo.noteTitle)
                .navigationDestination(for: NoteDestination.self) { destination in
                    noteDetail(
                        noteId: destination.noteId,
                        workspaceId: destination.workspaceId,
                        noteTitle: destination.noteTitle
                    )
                }
        }
    }

    private func noteDetail(noteId: String, workspaceId: String, noteTitle: String) -> some View {
        NoteDetailView(
            noteId: noteId,
            workspaceId: workspaceId,
            noteTitle: noteTitle,
            session: session,
            showsBackButton: !path.isEmpty,
            onNavigateToNote: navigate
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                IntentIconButton(icon: .close, label: "Done", action: onDone)
            }
            .intentToolbarSurface()
        }
    }

    private func navigate(noteId: String, workspaceId: String, noteTitle: String) {
        if workspaceId == Workspace.chiefWorkspaceId {
            path.append(NoteDestination(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle))
        } else {
            coordinator.onSelectNote(noteId, workspaceId: workspaceId, noteTitle: noteTitle)
        }
    }
}
