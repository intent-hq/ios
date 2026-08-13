import Foundation

/// Which leading icon a Context-tab note row gets. Mirrors the fe sidebar's
/// NotesPanel branch order (task metadata status → linked-task progress ring
/// → doc icon), with one iOS-specific addition: the spec/default note keeps
/// its star and shows the progress ring alongside it when its content links
/// task notes.
enum NoteRowIcon: Equatable {
    /// Spec/default note without linked tasks: star only.
    case star
    /// Spec/default note whose content links task notes: star + ring.
    case starWithProgressRing(TaskStats)
    /// Task note: icon for its metadata status.
    case taskStatus(TaskDisplayStatus)
    /// Non-task note whose content links task notes: progress ring.
    case progressRing(TaskStats)
    /// Any other note: muted doc icon (fe `getNoteIcon` fallback).
    case document

    /// Pick the treatment for `note`, resolving linked-task IDs in its
    /// content against `notes` (pass the store's full note list so the ring
    /// recomputes as task statuses change).
    static func kind(for note: Note, notes: [Note]) -> NoteRowIcon {
        if let status = note.taskDisplayStatus {
            return .taskStatus(status)
        }
        let stats = TaskContentParser.parseTaskStats(content: note.content, notes: notes)
        if note.isDefault {
            return stats.total > 0 ? .starWithProgressRing(stats) : .star
        }
        return stats.total > 0 ? .progressRing(stats) : .document
    }
}
