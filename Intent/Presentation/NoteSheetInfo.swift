import Foundation

struct NoteSheetInfo: Identifiable {
    let id = UUID()
    let noteId: String
    let workspaceId: String
    let noteTitle: String
}
