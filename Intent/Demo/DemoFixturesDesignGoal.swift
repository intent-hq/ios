#if DEBUG
import Foundation

extension DemoDesignFixtures {
    static let initialGoal = "Finish the release acceptance checks. Done when the required checks pass and rollback has been rehearsed. "
        + "Keep https://github.com/intent-hq/intent/issues/9646 current with the results."

    static func goalNotice(id: String, action: String, goal: String?) -> [String: Any] {
        let text = switch action {
        case "set": "Goal set: \(goal ?? "")"
        case "updated": "Goal updated: \(goal ?? "")"
        case "unchanged": "Goal unchanged: \(goal ?? "")"
        case "cleared": "Goal removed."
        default: goal.map { "Current goal: \($0)" } ?? "No goal set. Send /goal followed by what done looks like."
        }
        var row = message(id: id, role: "system", blocks: [DemoFixtures.textBlock(text)])
        row["metadata"] = ["type": "goal_command", "action": action, "goal": goal as Any? ?? NSNull()]
        return row
    }

    func goalCommandResponse(params: [String: Any]) -> Any? {
        guard scenario == .goal, params["interpretCommands"] as? Bool == true,
              let content = params["content"] as? String, ConversationGoal.isCommand(content) else { return nil }
        let statement = String(content.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(ConversationGoal.commandName.count))
        var command = applyGoal(ConversationGoal.normalized(statement), isCommand: true)
        command["name"] = "goal"
        return ["success": true, "queued": false, "command": command]
    }

    func setGoalResponse(params: [String: Any]) -> Any? {
        guard scenario == .goal else { return nil }
        return applyGoal(ConversationGoal.normalized(params["goal"] as? String ?? ""), isCommand: false)
    }

    private func applyGoal(_ next: String?, isCommand: Bool) -> [String: Any] {
        let action: String
        if next == nil, isCommand {
            action = "shown"
        } else if next == goal {
            action = "unchanged"
        } else if next == nil {
            action = "cleared"
        } else {
            action = goal == nil ? "set" : "updated"
        }
        if action != "shown", action != "unchanged" { goal = next }
        var result: [String: Any] = ["action": action, "goal": goal as Any? ?? NSNull()]
        if isCommand || action != "unchanged" {
            let id = "demo-design-goal-\(sentMessages.count)"
            sentMessages.append(Self.goalNotice(id: id, action: action, goal: goal))
            result["noticeMessageId"] = id
        }
        return result
    }
}
#endif
