import Foundation

extension DemoFixtures {
    static let designScenario = DemoDesignScenario.requested(by: ProcessInfo.processInfo.arguments)
        .map { DemoDesignFixtures(scenario: $0) }
}

/// Data scenarios only: appearance, keyboard, expansion and question layout
/// are still controlled by the real screen and user interactions.
enum DemoDesignScenario: String, CaseIterable {
    case blocker
    case composer
    case conversation
    case questionFlow = "question-flow"
    case questions
    case streaming
    case tools

    static func requested(by arguments: [String]) -> Self? {
        let prefix = "--demo-design-scenario="
        guard DemoMode.demoDataRequested(by: arguments),
              let argument = arguments.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Self(rawValue: String(argument.dropFirst(prefix.count)))
    }
}

/// An in-memory fixture daemon for the design workspace. State changes return
/// ordinary RPC payloads and chat snapshots; no view/store state is set here.
@MainActor
final class DemoDesignFixtures {
    static let workspaceId = "demo-ws-agent-design"
    static let agentId = "demo-agent-design"
    static let agentName = "Continue Spec Writer"
    static let questionMessageId = "demo-design-questions"
    static let monitorId = "demo-design-pr-56"

    let scenario: DemoDesignScenario
    private(set) var isStreaming: Bool
    private(set) var questionsResolved = false
    private(set) var questionsDismissed = false
    private(set) var monitorCancelled = false
    private var sentMessages: [[String: Any]] = []
    private var sequence = 0

    init(scenario: DemoDesignScenario) {
        self.scenario = scenario
        isStreaming = scenario == .streaming
    }

    var hasQuestions: Bool { scenario == .questions || scenario == .questionFlow }
    var pendingQuestionId: String { hasQuestions && !questionsResolved ? Self.questionMessageId : "" }
    var messages: [[String: Any]] { initialMessages + sentMessages }

    // This switch is the deliberately small design-demo protocol surface.
    // swiftlint:disable:next cyclomatic_complexity
    func response(for method: String, params: [String: Any]) -> Any? {
        let ownsAgent = params["agentId"] as? String == Self.agentId
        let ownsWorkspace = params["workspaceId"] as? String == Self.workspaceId
        switch method {
        case "workspace.list":
            return ["workspaces": [workspace]]
        case "agent.list" where ownsWorkspace:
            return ["agents": [agent]]
        case "agent.get" where ownsAgent:
            return ["agent": agent]
        case "agent.getConversation" where ownsAgent:
            return ["messages": messages, "truncated": false, "totalMessages": messages.count]
        case "chat.subscribe" where ownsAgent:
            sequence = 0
            return ["subscriptionId": DemoFixtures.chatSubscriptionId(agentId: Self.agentId)]
        case "agent.sendMessage" where ownsAgent:
            guard let messageId = params["messageId"] as? String,
                  let content = params["content"] as? String else { return nil }
            var row = Self.message(id: messageId, role: "user", blocks: [DemoFixtures.textBlock(content)])
            if let metadata = params["messageMetadata"] as? [String: Any] {
                row["metadata"] = metadata
                if metadata["type"] as? String == "question_answers",
                   metadata["answeredQuestionsMessageId"] as? String == pendingQuestionId {
                    questionsResolved = true
                }
            }
            if !sentMessages.contains(where: { $0["id"] as? String == messageId }) { sentMessages.append(row) }
            isStreaming = true
            return ["success": true, "queued": false, "messageId": messageId]
        case "agent.stop" where ownsAgent:
            isStreaming = false
            return ["success": true]
        case "agent.dismissQuestions" where ownsAgent:
            guard params["messageId"] as? String == Self.questionMessageId, hasQuestions else { return nil }
            questionsResolved = true
            questionsDismissed = true
            return ["success": true, "dismissedQuestionsMessageId": Self.questionMessageId]
        case "prMonitor.list" where ownsWorkspace:
            let matchesAgent = params["agentId"] == nil || ownsAgent
            return ["monitors": matchesAgent && scenario == .conversation && !monitorCancelled ? [monitor] : []]
        case "prMonitor.cancel" where ownsWorkspace && params["monitorId"] as? String == Self.monitorId:
            monitorCancelled = true
            return ["success": true]
        case "prMonitor.flush" where ownsWorkspace && params["monitorId"] as? String == Self.monitorId:
            return ["success": true]
        default:
            return nil
        }
    }

    /// Called after response mutation and before its acknowledgement is
    /// returned, exercising the live router's normal early-push buffering.
    func subscriptionPush(for method: String, params: [String: Any]) -> SubscriptionPush? {
        guard params["agentId"] as? String == Self.agentId,
              ["chat.subscribe", "agent.sendMessage", "agent.stop"].contains(method) else { return nil }
        if method != "chat.subscribe" { sequence += 1 }
        return SubscriptionPush(
            subscriptionId: DemoFixtures.chatSubscriptionId(agentId: Self.agentId),
            seq: sequence,
            conversationSnapshot: messages,
            metadata: ["truncated": false, "totalMessages": messages.count, "isResponding": isStreaming]
        )
    }

    // Nil means this RPC owes no event; an empty event would still be dispatched.
    func event(for method: String, params: [String: Any]) -> [String: Any]? { // swiftlint:disable:this discouraged_optional_collection
        if params["agentId"] as? String == Self.agentId,
           ["agent.sendMessage", "agent.dismissQuestions"].contains(method) {
            return [
                "type": "agent:updated", "data": [
                    "agentId": Self.agentId,
                    "pendingQuestionsMessageId": pendingQuestionId,
                    "dismissedQuestionsMessageId": questionsDismissed ? Self.questionMessageId : ""
                ]
            ]
        }
        guard params["workspaceId"] as? String == Self.workspaceId,
              params["monitorId"] as? String == Self.monitorId,
              ["prMonitor.cancel", "prMonitor.flush"].contains(method) else { return nil }
        return ["type": method == "prMonitor.cancel" ? "prMonitor:cancelled" : "prMonitor:emitted", "data": monitor]
    }
}
