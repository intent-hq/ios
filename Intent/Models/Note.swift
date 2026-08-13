import Foundation

struct Note: Identifiable, Equatable {
    let id: String
    let title: String
    let content: String
    let tags: [String]
    let isDefault: Bool
    let isArchived: Bool
    let taskStatus: String?
    let parentId: String?
    let createdAt: String
    let updatedAt: String

    /// Display treatment for `taskStatus`; nil when the note is not a task.
    /// Note: the checkbox markers in `content` are unaffected — the wire
    /// checkbox vocabulary is only `[ ]`/`[x]`/`[/]`; `blocked` and
    /// `discussion_needed` exist only in task-note metadata status.
    var taskDisplayStatus: TaskDisplayStatus? {
        taskStatus.map { TaskDisplayStatus(wire: $0) }
    }

    /// Copy with different content (optimistic local updates).
    func withContent(_ newContent: String) -> Note {
        Note(
            id: id, title: title, content: newContent, tags: tags,
            isDefault: isDefault, isArchived: isArchived, taskStatus: taskStatus,
            parentId: parentId, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    /// Copy with a different task-note status (optimistic local updates).
    func withTaskStatus(_ newStatus: String) -> Note {
        Note(
            id: id, title: title, content: content, tags: tags,
            isDefault: isDefault, isArchived: isArchived, taskStatus: newStatus,
            parentId: parentId, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    /// A short preview of the content for list display
    var preview: String? {
        let stripped = content
            .replacingOccurrences(of: "- [ ] ", with: "")
            .replacingOccurrences(of: "- [x] ", with: "")
            .replacingOccurrences(of: "- [/] ", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = stripped.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let line = firstLine else { return nil }
        return String(line.prefix(120))
    }

    static func parseNote(_ dict: [String: Any]) -> Note? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String else { return nil }

        let metadata = dict["metadata"] as? [String: Any]
        let task = metadata?["task"] as? [String: Any]

        let now = ISO8601DateFormatter().string(from: Date())

        return Note(
            id: id,
            title: title,
            content: dict["content"] as? String ?? "",
            tags: dict["tags"] as? [String] ?? [],
            isDefault: dict["isDefault"] as? Bool ?? false,
            isArchived: dict["isArchived"] as? Bool ?? false,
            taskStatus: task?["status"] as? String,
            parentId: dict["parentId"] as? String,
            createdAt: dict["createdAt"] as? String ?? now,
            updatedAt: dict["updatedAt"] as? String ?? now
        )
    }
}

