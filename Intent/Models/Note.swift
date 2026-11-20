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
    let assignedAgentIds: [String]
    let dependsOn: [String]
    let conflictsWith: [String]
    let unmetDependsOn: [String]
    let estimatedEffort: String?
    let contentPreview: String?
    let contentLength: Int?
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

    var isContentStale: Bool {
        if let contentLength, contentLength > 0, content.isEmpty { return true }
        return false
    }

    var taskDisplayStatus: TaskDisplayStatus? {
        taskStatus.map { TaskDisplayStatus(wire: $0) }
    }

    var needsFullContent: Bool {
        isContentStale || contentTruncated
    }

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
