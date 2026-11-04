import Foundation

extension NoteStore {
    // MARK: - Task status writes

    /// Restore one note's pre-request snapshot after a failed optimistic
    /// write. Scoped to that note by id so concurrent deltas / optimistic
    /// writes to other notes that landed mid-flight are not clobbered; the
    /// note's own `note:updated` event reconciles any remaining drift.
    private func rollback(_ original: Note) {
        if let idx = notes.firstIndex(where: { $0.id == original.id }) {
            notes[idx] = original
        }
    }

    /// Update a plain checkbox line's status via the daemon's `task.update`
    /// (PROTOCOL §5.4 atomic single-line edit). `line` is 1-based; `status` is
    /// the checkbox vocabulary ("todo" | "in-progress" | "done"). The marker
    /// rewrite is applied optimistically to the local cache and reverted on
    /// error; the confirming `note:updated` event reconciles the real state.
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

    /// Update a task note's metadata status via `task.updateNoteStatus`
    /// (PROTOCOL §5.4 task-note status vocabulary). Optimistic local update,
    /// reverted on error; `note:updated` confirms the change.
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
