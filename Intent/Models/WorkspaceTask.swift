import Foundation

/// Canonical task facts for a workspace (matches WorkspaceTask from intentd).
/// Returned by task.list and task.subscribe.
struct WorkspaceTask: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let status: String
    let updatedAt: String

    /// Display treatment for the wire `status` string.
    var displayStatus: TaskDisplayStatus {
        TaskDisplayStatus(wire: status)
    }

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

/// Display treatment for the task-note status vocabulary (PROTOCOL §5.4):
/// not_started | waiting | discussion_needed | blocked | in_progress |
/// review_required | complete | cancelled. Task statuses stay open strings on
/// the wire; unrecognized values fall back to `.unknown` so newer daemons
/// degrade gracefully. `blocked` and `discussion_needed` are pending
/// attention-request states (`ws.agent.reportBlocker` / `requestDiscussion`)
/// and get a distinct treatment rather than being lumped with unknown.
enum TaskDisplayStatus: Equatable {
    case notStarted
    case waiting
    case discussionNeeded
    case blocked
    case inProgress
    case reviewRequired
    case complete
    case cancelled
    case unknown

    init(wire: String) {
        switch wire {
        case "not_started", "todo": self = .notStarted
        case "waiting": self = .waiting
        case "discussion_needed": self = .discussionNeeded
        case "blocked": self = .blocked
        case "in_progress", "in-progress": self = .inProgress
        case "review_required": self = .reviewRequired
        case "complete", "done": self = .complete
        case "cancelled": self = .cancelled
        default: self = .unknown
        }
    }

    var emoji: String {
        switch self {
        case .notStarted: return "☐"
        case .waiting: return "⏳"
        case .discussionNeeded: return "💬"
        case .blocked: return "⛔"
        case .inProgress: return "🔄"
        case .reviewRequired: return "👀"
        case .complete: return "✅"
        case .cancelled: return "🚫"
        case .unknown: return "❔"
        }
    }

    var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .waiting: return "Waiting"
        case .discussionNeeded: return "Discussion needed"
        case .blocked: return "Blocked"
        case .inProgress: return "In progress"
        case .reviewRequired: return "Review required"
        case .complete: return "Complete"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    /// True for statuses raised by agent attention requests — the task is
    /// waiting on the user rather than progressing.
    var needsAttention: Bool {
        self == .blocked || self == .discussionNeeded
    }
}
