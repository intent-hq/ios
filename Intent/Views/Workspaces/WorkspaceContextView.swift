import SwiftUI

struct WorkspaceContextView: View {
    let workspaceId: String
    let noteStore: NoteStore
    let filesStore: WorkspaceFilesStore
    @Binding var notesExpanded: Bool
    @Binding var filesExpanded: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionSpacing) {
            WorkspaceChangesSection(
                title: "Notes", identifier: "notes", accessibilityPrefix: "context", isExpanded: $notesExpanded
            ) {
                NoteListView(workspaceId: workspaceId, noteStore: noteStore, isEmbedded: true)
            }
            WorkspaceChangesSection(
                title: "Files", identifier: "files", accessibilityPrefix: "context", isExpanded: $filesExpanded
            ) {
                WorkspaceFilesView(workspaceId: workspaceId, store: filesStore)
            }
        }
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.bottom, WorkspaceDetailStyle.pageInset)
        .task(id: workspaceId) { await filesStore.start(workspaceId: workspaceId) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await filesStore.refresh() } }
        }
    }
}
