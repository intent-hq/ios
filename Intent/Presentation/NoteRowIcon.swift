import Foundation

enum NoteRowIcon: Equatable {
    case document
    case progressRing(TaskStats)
    case star
    case starWithProgressRing(TaskStats)
    case taskStatus(TaskDisplayStatus)

    static func kind(for note: Note, notes: [Note]) -> Self {
        if let status = note.taskDisplayStatus {
            return .taskStatus(childrenDerivedStatus(for: note, notes: notes) ?? status)
        }
        let stats = TaskContentParser.parseTaskStats(content: note.content, notes: notes)
        if note.isDefault {
            return stats.total > 0 ? .starWithProgressRing(stats) : .star
        }
        return stats.total > 0 ? .progressRing(stats) : .document
    }

    private static func childrenDerivedStatus(for note: Note, notes: [Note]) -> TaskDisplayStatus? {
        let children = notes.filter { !$0.isArchived && $0.parentId == note.id }
        guard !children.isEmpty else { return nil }
        if children.allSatisfy({ $0.taskStatus == "complete" }) { return .complete }
        if children.allSatisfy({ $0.taskStatus == "not_started" }) { return .notStarted }
        return .inProgress
    }
}
