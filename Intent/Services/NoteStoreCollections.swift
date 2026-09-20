extension NoteStore {
    /// Sorted notes: spec (isDefault) first, then by createdAt ascending (oldest first). Archived notes excluded.
    var sortedNotes: [Note] {
        notes
            .filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                // Match Electron behavior: sort by createdAt ascending (oldest first, newest at bottom)
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Root notes (no parentId, or parentId not found in current notes). Archived excluded.
    var rootNotes: [Note] {
        let noteIds = Set(notes.map { $0.id })
        return sortedNotes.filter { note in
            guard let parentId = note.parentId else { return true }
            return !noteIds.contains(parentId)
        }
    }

    /// Get child notes for a given parent ID, sorted by createdAt ascending.
    func childNotes(of parentId: String) -> [Note] {
        notes
            .filter { !$0.isArchived && $0.parentId == parentId }
            .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
    }

    /// Check if a note has children.
    func hasChildren(_ noteId: String) -> Bool {
        notes.contains { !$0.isArchived && $0.parentId == noteId }
    }

    /// Find a note by ID.
    func note(byId id: String) -> Note? {
        notes.first { $0.id == id }
    }
}
