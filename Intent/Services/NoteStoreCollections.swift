extension NoteStore {
    var sortedNotes: [Note] {
        notes
            .filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    var rootNotes: [Note] {
        let noteIds = Set(notes.map { $0.id })
        return sortedNotes.filter { note in
            guard let parentId = note.parentId else { return true }
            return !noteIds.contains(parentId)
        }
    }

    func childNotes(of parentId: String) -> [Note] {
        notes
            .filter { !$0.isArchived && $0.parentId == parentId }
            .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
    }

    func hasChildren(_ noteId: String) -> Bool {
        notes.contains { !$0.isArchived && $0.parentId == noteId }
    }

    func note(byId id: String) -> Note? {
        notes.first { $0.id == id }
    }
}
