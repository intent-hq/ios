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
    /// Remaining `metadata.task` fields (PROTOCOL §5.2/§5.4). All are
    /// omitted-when-empty on the wire; empty array / nil when absent or when
    /// the note is not a task.
    let assignedAgentIds: [String]
    let dependsOn: [String]
    let conflictsWith: [String]
    /// Daemon-computed projection of `dependsOn` entries not yet complete.
    let unmetDependsOn: [String]
    let estimatedEffort: String?
    /// Slim `note.list` projection fields (PROTOCOL §5.2 `projection: "slim"`):
    /// slim rows omit `content` and carry the first 500 chars plus the total
    /// char count instead. nil on full rows.
    let contentPreview: String?
    let contentLength: Int?
    /// True when `content` is only a prefix of the note: the daemon cut a row
    /// too large for one read (PROTOCOL §5.2 "Bounded note and comment reads")
    /// and the rest could not be read. `contentBytes` is the full UTF-8 size.
    let contentTruncated: Bool
    let contentBytes: Int?

    init(
        id: String,
        title: String,
        content: String,
        tags: [String],
        isDefault: Bool,
        isArchived: Bool,
        taskStatus: String?,
        parentId: String?,
        createdAt: String,
        updatedAt: String,
        assignedAgentIds: [String] = [],
        dependsOn: [String] = [],
        conflictsWith: [String] = [],
        unmetDependsOn: [String] = [],
        estimatedEffort: String? = nil,
        contentPreview: String? = nil,
        contentLength: Int? = nil,
        contentTruncated: Bool = false,
        contentBytes: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.taskStatus = taskStatus
        self.parentId = parentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assignedAgentIds = assignedAgentIds
        self.dependsOn = dependsOn
        self.conflictsWith = conflictsWith
        self.unmetDependsOn = unmetDependsOn
        self.estimatedEffort = estimatedEffort
        self.contentPreview = contentPreview
        self.contentLength = contentLength
        self.contentTruncated = contentTruncated
        self.contentBytes = contentBytes
    }

    /// True when this is a slim-projection row whose full body has not been
    /// loaded: the daemon reported a non-empty content length but the local
    /// row carries no content. Full rows (no `contentLength`) and genuinely
    /// empty notes (`contentLength == 0`) are never stale.
    var isContentStale: Bool {
        if let contentLength, contentLength > 0, content.isEmpty { return true }
        return false
    }

    /// Display treatment for `taskStatus`; nil when the note is not a task.
    /// Note: the checkbox markers in `content` are unaffected — the wire
    /// checkbox vocabulary is only `[ ]`/`[x]`/`[/]`; `blocked` and
    /// `discussion_needed` exist only in task-note metadata status.
    var taskDisplayStatus: TaskDisplayStatus? {
        taskStatus.map { TaskDisplayStatus(wire: $0) }
    }

    /// True when the cached row lacks the note's whole body: a slim row
    /// without content, or a row the daemon cut to fit one read.
    var needsFullContent: Bool {
        isContentStale || contentTruncated
    }

    /// Copy carrying `source`'s body and cut markers (grafting a fetched body
    /// onto a cached list row whose metadata should win).
    func withBody(of source: Self) -> Self {
        Self(
            id: id,
            title: title,
            content: source.content,
            tags: tags,
            isDefault: isDefault,
            isArchived: isArchived,
            taskStatus: taskStatus,
            parentId: parentId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            assignedAgentIds: assignedAgentIds,
            dependsOn: dependsOn,
            conflictsWith: conflictsWith,
            unmetDependsOn: unmetDependsOn,
            estimatedEffort: estimatedEffort,
            contentPreview: contentPreview,
            contentLength: contentLength,
            contentTruncated: source.contentTruncated,
            contentBytes: source.contentBytes
        )
    }

    /// Copy with different content (optimistic local updates).
    func withContent(_ newContent: String) -> Self {
        Self(
            id: id,
            title: title,
            content: newContent,
            tags: tags,
            isDefault: isDefault,
            isArchived: isArchived,
            taskStatus: taskStatus,
            parentId: parentId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            assignedAgentIds: assignedAgentIds,
            dependsOn: dependsOn,
            conflictsWith: conflictsWith,
            unmetDependsOn: unmetDependsOn,
            estimatedEffort: estimatedEffort,
            contentPreview: contentPreview,
            contentLength: contentLength,
            contentTruncated: contentTruncated,
            contentBytes: contentBytes
        )
    }

    /// Copy with a different task-note status (optimistic local updates).
    func withTaskStatus(_ newStatus: String) -> Self {
        Self(
            id: id,
            title: title,
            content: content,
            tags: tags,
            isDefault: isDefault,
            isArchived: isArchived,
            taskStatus: newStatus,
            parentId: parentId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            assignedAgentIds: assignedAgentIds,
            dependsOn: dependsOn,
            conflictsWith: conflictsWith,
            unmetDependsOn: unmetDependsOn,
            estimatedEffort: estimatedEffort,
            contentPreview: contentPreview,
            contentLength: contentLength,
            contentTruncated: contentTruncated,
            contentBytes: contentBytes
        )
    }

    /// A short preview of the content for list display. Slim rows carry no
    /// `content`, so fall back to the daemon's `contentPreview` (first 500
    /// chars) — plenty for a one-line excerpt.
    var preview: String? {
        let body = content.isEmpty ? (contentPreview ?? "") : content
        let stripped = body
            .replacingOccurrences(of: "- [ ] ", with: "")
            .replacingOccurrences(of: "- [x] ", with: "")
            .replacingOccurrences(of: "- [/] ", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = stripped.components(separatedBy: .newlines).first { line in
            !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let line = firstLine else { return nil }
        return String(line.prefix(Constants.Note.previewCharacterLimit))
    }

    static func parseNote(_ dict: [String: Any]) -> Self? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String else { return nil }

        let metadata = dict["metadata"] as? [String: Any]
        let task = metadata?["task"] as? [String: Any]

        let now = ISO8601DateFormatter().string(from: Date())

        return Self(
            id: id,
            title: title,
            content: dict["content"] as? String ?? "",
            tags: dict["tags"] as? [String] ?? [],
            isDefault: dict["isDefault"] as? Bool ?? false,
            isArchived: dict["isArchived"] as? Bool ?? false,
            taskStatus: task?["status"] as? String,
            parentId: dict["parentId"] as? String,
            createdAt: dict["createdAt"] as? String ?? now,
            updatedAt: dict["updatedAt"] as? String ?? now,
            assignedAgentIds: task?["assignedAgentIds"] as? [String] ?? [],
            dependsOn: task?["dependsOn"] as? [String] ?? [],
            conflictsWith: task?["conflictsWith"] as? [String] ?? [],
            unmetDependsOn: task?["unmetDependsOn"] as? [String] ?? [],
            estimatedEffort: task?["estimatedEffort"] as? String,
            contentPreview: dict["contentPreview"] as? String,
            contentLength: dict["contentLength"] as? Int,
            contentTruncated: dict["contentTruncated"] as? Bool ?? false,
            contentBytes: dict["contentBytes"] as? Int
        )
    }
}
