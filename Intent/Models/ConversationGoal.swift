import Foundation

nonisolated enum ConversationGoal {
    static let maximumLength = 1000
    static let commandName = "/goal"
    static let attachmentsError = "/goal does not take attachments. Remove the attachments and send it again."

    static func isCommand(_ content: String) -> Bool {
        let scalars = content.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let name = commandName.unicodeScalars
        guard scalars.starts(with: name) else { return false }
        guard let next = scalars.dropFirst(name.count).first else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(next)
    }

    static func parse(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isTooLong(_ text: String) -> Bool {
        (normalized(text)?.count ?? 0) > maximumLength
    }

    static func linkedText(_ goal: String) -> AttributedString {
        var text = AttributedString(goal)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        let range = NSRange(goal.startIndex..., in: goal)
        for match in detector.matches(in: goal, range: range) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let stringRange = Range(match.range, in: goal),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: text),
                  let upper = AttributedString.Index(stringRange.upperBound, within: text) else { continue }
            text[lower..<upper].link = url
        }
        return text
    }

    static func links(in goal: String) -> [URL] {
        linkedText(goal).runs.compactMap(\.link)
    }
}

nonisolated struct GoalCommandResult: Equatable, Sendable {
    let action: String
    let goal: String?
    let noticeMessageId: String?

    init(action: String, goal: String?, noticeMessageId: String?) {
        self.action = action
        self.goal = goal
        self.noticeMessageId = noticeMessageId
    }

    init?(command value: Any?) {
        guard let command = value as? [String: Any], command["name"] as? String == "goal",
              let action = command["action"] as? String else { return nil }
        self.init(action: action, goal: ConversationGoal.parse(command["goal"]), noticeMessageId: command["noticeMessageId"] as? String)
    }

    init?(setGoalResponse value: Any) {
        guard let response = value as? [String: Any], let action = response["action"] as? String else { return nil }
        self.init(action: action, goal: ConversationGoal.parse(response["goal"]), noticeMessageId: response["noticeMessageId"] as? String)
    }
}

struct GoalCommandNotice: Equatable {
    enum Action: String {
        case set
        case updated
        case unchanged
        case cleared
        case shown
    }

    let action: Action?
    let goal: String?
    let text: String

    static let fallbackLabel = "Goal updated"

    var label: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch action {
        case .set: return goal.map { "Goal set: \($0)" } ?? Self.fallbackLabel
        case .updated: return goal.map { "Goal updated: \($0)" } ?? Self.fallbackLabel
        case .unchanged: return goal.map { "Goal unchanged: \($0)" } ?? Self.fallbackLabel
        case .cleared: return "Goal removed."
        case .shown: return goal.map { "Current goal: \($0)" } ?? "No goal set. Send /goal followed by what done looks like."
        case nil: return Self.fallbackLabel
        }
    }
}

extension ConversationMessage {
    var goalCommandNotice: GoalCommandNotice? {
        guard role == .system, metadata["type"]?.value as? String == "goal_command" else { return nil }
        return GoalCommandNotice(
            action: (metadata["action"]?.value as? String).flatMap(GoalCommandNotice.Action.init(rawValue:)),
            goal: ConversationGoal.parse(metadata["goal"]?.value),
            text: joinedTextContent
        )
    }
}
