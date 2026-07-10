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

    /// Returns content with task checkbox markers replaced by emoji
    var renderedContent: String {
        return content
            .replacingOccurrences(of: "- [ ] ", with: "- ☐ ")
            .replacingOccurrences(of: "- [x] ", with: "- ✅ ")
            .replacingOccurrences(of: "- [/] ", with: "- 🔄 ")
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

