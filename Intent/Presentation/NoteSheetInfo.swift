import Foundation

struct NoteSheetInfo: Identifiable, Equatable {
    let id = UUID()
    let noteId: String
    let workspaceId: String
    let noteTitle: String
}
