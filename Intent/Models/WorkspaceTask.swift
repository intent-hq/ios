import Foundation

/// Canonical task facts for a workspace (matches WorkspaceTask from intentd).
/// Returned by task.list and task.subscribe.
struct WorkspaceTask: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let status: String
    let updatedAt: String

    static func parseTask(_ dict: [String: Any]) -> WorkspaceTask? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let status = dict["status"] as? String,
              let updatedAt = dict["updatedAt"] as? String else {
            return nil
        }

        return WorkspaceTask(
            id: id,
            title: title,
            status: status,
            updatedAt: updatedAt
        )
    }
}
