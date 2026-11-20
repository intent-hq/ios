import Foundation

extension NoteStore {
    private func rollback(_ original: Note) {
        if let idx = notes.firstIndex(where: { $0.id == original.id }) {
            notes[idx] = original
        }
    }

    @discardableResult
    func updateTaskLineStatus(noteId: String, workspaceId: String, line: Int, status: String) async -> Bool {
        var original: Note?
        if let idx = notes.firstIndex(where: { $0.id == noteId }),
           let rewritten = NoteContentSegmenter.replacingCheckboxMarker(
               in: notes[idx].content,
               line: line,
               status: status
           ) {
            original = notes[idx]
            notes[idx] = notes[idx].withContent(rewritten)
        }
        do {
            _ = try await connectionManager.request("task.update", params: [
                "workspaceId": workspaceId,
                "noteId": noteId,
                "line": line,
                "status": status
            ])
            return true
        } catch {
            if let original { rollback(original) }
            AppLog.notes.error("[NoteStore] task.update failed: \(error)")
            return false
        }
    }

    @discardableResult
    func updateTaskNoteStatus(noteId: String, workspaceId: String, status: String) async -> Bool {
        var original: Note?
        if let idx = notes.firstIndex(where: { $0.id == noteId }) {
            original = notes[idx]
            notes[idx] = notes[idx].withTaskStatus(status)
        }
        do {
            _ = try await connectionManager.request("task.updateNoteStatus", params: [
                "workspaceId": workspaceId,
                "noteId": noteId,
                "status": status
            ])
            return true
        } catch {
            if let original { rollback(original) }
            AppLog.notes.error("[NoteStore] task.updateNoteStatus failed: \(error)")
            return false
        }
    }
}
