import Foundation
import Combine

@MainActor
class NoteStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var isLoading = false

    private var workspaceId: String?
    private var eventHandlerId: UUID?

    /// Optional callback invoked when a note event is received (for detail view refresh)
    var onNoteChanged: (() -> Void)?

    /// Sorted notes: spec (isDefault) first, then by createdAt ascending (oldest first). Archived notes excluded.
    var sortedNotes: [Note] {
        notes
            .filter { !$0.isArchived }
            .sorted { a, b in
                if a.isDefault != b.isDefault {
                    return a.isDefault
                }
                // Match Electron behavior: sort by createdAt ascending (oldest first, newest at bottom)
                return a.createdAt < b.createdAt
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
            .sorted { a, b in a.createdAt < b.createdAt }
    }

    /// Check if a note has children
    func hasChildren(_ noteId: String) -> Bool {
        notes.contains { !$0.isArchived && $0.parentId == noteId }
    }

    /// Find a note by ID
    func note(byId id: String) -> Note? {
        notes.first { $0.id == id }
    }

    func fetchNotes(workspaceId: String) async {
        let workspaceChanged = self.workspaceId != workspaceId
        // If workspace changed, clear notes immediately to prevent stale data
        if workspaceChanged {
            notes = []
        }
        self.workspaceId = workspaceId
        // Only show loading indicator if we have no notes to display
        if notes.isEmpty {
            isLoading = true
        }
        do {
            let result = try await ConnectionManager.shared.request(
                "note.list",
                params: ["workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let items = dict["notes"] as? [[String: Any]] {
                notes = items.compactMap { Note.parseNote($0) }
            }
        } catch {
            print("[NoteStore] Failed to fetch notes: \(error)")
        }
        isLoading = false
    }

    func fetchNote(noteId: String, workspaceId: String) async -> Note? {
        do {
            let result = try await ConnectionManager.shared.request(
                "note.get",
                params: ["noteId": noteId, "workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let noteDict = dict["note"] as? [String: Any] {
                return Note.parseNote(noteDict)
            }
        } catch {
            print("[NoteStore] Failed to fetch note: \(error)")
        }
        return nil
    }

    func startObservingEvents(workspaceId: String? = nil) {
        if let workspaceId = workspaceId {
            self.workspaceId = workspaceId
        }

        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            ConnectionManager.shared.removeEventHandler(id: handlerId)
        }

        // Register event handler on ConnectionManager
        // (server subscription is handled centrally by ConnectionManager.subscribeToAllEvents)
        eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(method, params: params)
            }
        }
    }

    private func handleEvent(_ method: String, params: Any) {
        guard let dict = params as? [String: Any] else { return }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String else { return }

        let eventWorkspaceId = event["workspaceId"] as? String
        guard eventWorkspaceId == workspaceId || eventWorkspaceId == nil else { return }

        switch eventType {
        case let t where t.hasPrefix("note:"):
            guard let workspaceId = workspaceId else { return }
            Task { await fetchNotes(workspaceId: workspaceId) }
            onNoteChanged?()
        default:
            break
        }
    }
}

