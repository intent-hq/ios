import Foundation

struct WorkspaceTask: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let status: String
    let updatedAt: String

    var displayStatus: TaskDisplayStatus {
        TaskDisplayStatus(wire: status)
    }

    static func parseTask(_ dict: [String: Any]) -> Self? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let status = dict["status"] as? String,
              let updatedAt = dict["updatedAt"] as? String else {
            return nil
        }

        return Self(
            id: id,
            title: title,
            status: status,
            updatedAt: updatedAt
        )
    }
}

enum TaskDisplayStatus: Equatable {
    case blocked
    case cancelled
    case complete
    case discussionNeeded
    case inProgress
    case notStarted
    case reviewRequired
    case unknown
    case waiting

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

    var needsAttention: Bool {
        self == .blocked || self == .discussionNeeded
    }
}
