import Foundation

extension DemoFixtures {
    static let designScenario = DemoDesignScenario.requested(by: ProcessInfo.processInfo.arguments)
        .map { DemoDesignFixtures(scenario: $0) }
}

/// Data scenarios only: appearance, keyboard, expansion and question layout
/// are still controlled by the real screen and user interactions.
enum DemoDesignScenario: String, CaseIterable {
    case agentGroups = "agent-groups"
    case agentGroupsLarge = "agent-groups-large"
    case agentGroupsRetry = "agent-groups-retry"
    case blocker
    case claudeTools = "claude-tools"
    case composer
    case context
    case conversation
    case empty
    case history
    case mermaid
    case mermaidHistory = "mermaid-history"
    case questionCards = "question-cards"
    case questionFlow = "question-flow"
    case questions
    case queue
    case streaming
    case tables
    case tools
    case watcher

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
    private static let archivedMessageCount = 100

    let scenario: DemoDesignScenario
    private(set) var isStreaming: Bool
    private(set) var questionsResolved = false
    private(set) var questionsDismissed = false
    private(set) var monitorCancelled = false
    private(set) var modelId = "default-model"
    private var sentMessages: [[String: Any]] = []
    private var queuedMessages: [[String: Any]] = []
    private var sequence = 0
    private var failedBackgroundRead = false

    init(scenario: DemoDesignScenario) {
        self.scenario = scenario
        isStreaming = scenario == .streaming || scenario == .queue
        if scenario == .queue {
            queuedMessages = ["Hmm all these graders seem to be", "Keep the existing composer unchanged"].enumerated().map { index, text in
                ["id": "demo-queue-\(index)", "content": text, "queuedAt": Self.timestamp, "position": index]
            }
        }
    }

    var hasQuestions: Bool { scenario == .questions || scenario == .questionFlow || scenario == .questionCards }
    var pendingQuestionId: String { hasQuestions && !questionsResolved ? Self.questionMessageId : "" }
    var messages: [[String: Any]] { initialMessages + sentMessages }
    private var historyIsTruncated: Bool { scenario == .history }
    private var totalMessageCount: Int { messages.count + (historyIsTruncated ? Self.archivedMessageCount : 0) }

    func response(for method: String, params: [String: Any]) -> Any? {
        let ownsAgent = params["agentId"] as? String == Self.agentId
        let ownsWorkspace = params["workspaceId"] as? String == Self.workspaceId
        if ownsAgent, let response = queueResponse(for: method, params: params) { return response }
        if ownsAgent, let response = agentResponse(for: method, params: params) { return response }
        if ownsWorkspace, let response = monitorResponse(for: method, params: params) { return response }
        switch method {
        case "workspace.list":
            return ["workspaces": [workspace] + (scenario == .mermaidHistory ? DemoFixtures.workspaces : [])]
        case "note.list" where ownsWorkspace && scenario == .context: return ["notes": contextNotes]
        case "note.get" where ownsWorkspace && scenario == .context:
            return contextNotes.first { $0["id"] as? String == params["noteId"] as? String }.map { ["note": $0] }
        case "agent.list" where ownsWorkspace:
            return agentListResponse(params: params)
        default:
            return nil
        }
    }

    private func agentResponse(for method: String, params: [String: Any]) -> Any? {
        switch method {
        case "agent.get": return ["agent": agent]
        case "agent.setModel" where params["workspaceId"] as? String == Self.workspaceId:
            guard let modelId = params["modelId"] as? String else { return nil }
            self.modelId = modelId
            return ["success": true]
        case "agent.getConversation":
            return ["messages": messages, "truncated": historyIsTruncated, "totalMessages": totalMessageCount]
        case "chat.subscribe":
            sequence = 0
            return ["subscriptionId": DemoFixtures.chatSubscriptionId(agentId: Self.agentId)]
        case "agent.sendMessage":
            return sendMessageResponse(params: params)
        case "agent.stop":
            isStreaming = false
            return ["success": true]
        case "agent.dismissQuestions":
            guard params["messageId"] as? String == Self.questionMessageId, hasQuestions else { return nil }
            questionsResolved = true
            questionsDismissed = true
            return ["success": true, "dismissedQuestionsMessageId": Self.questionMessageId]
        default:
            return nil
        }
    }

    private func sendMessageResponse(params: [String: Any]) -> Any? {
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
    }

    private func monitorResponse(for method: String, params: [String: Any]) -> Any? {
        switch method {
        case "prMonitor.list":
            let matchesAgent = params["agentId"] == nil || params["agentId"] as? String == Self.agentId
            return ["monitors": matchesAgent && scenario == .conversation && !monitorCancelled ? [monitor] : []]
        case "prMonitor.cancel" where params["monitorId"] as? String == Self.monitorId:
            monitorCancelled = true
            return ["success": true]
        case "prMonitor.flush" where params["monitorId"] as? String == Self.monitorId:
            return ["success": true]
        default:
            return nil
        }
    }

    private func agentListResponse(params: [String: Any]) -> [String: Any] {
        if scenario == .agentGroupsLarge {
            return DemoAgentListFixtures.response(rows: DemoAgentListFixtures.largeGroupRows, params: params)
        }
        if scenario == .agentGroupsRetry, params["scope"] as? String == "background", !failedBackgroundRead {
            failedBackgroundRead = true
            return ["error": "Temporary demo failure"]
        }
        let rows = scenario == .agentGroups || scenario == .agentGroupsRetry ? DemoAgentListFixtures.groupRows : [agent]
        return DemoAgentListFixtures.response(rows: rows, params: params)
    }

    private func queueResponse(for method: String, params: [String: Any]) -> Any? {
        switch method {
        case "agent.getQueue":
            return ["queue": queuedMessages]
        case "agent.editQueuedMessage":
            guard let index = queuedMessages.firstIndex(where: { $0["id"] as? String == params["messageId"] as? String }),
                  let content = params["content"] as? String else { return nil }
            queuedMessages[index]["content"] = content
            return ["success": true]
        case "agent.removeQueuedMessage", "agent.sendQueuedMessageNow":
            guard let index = queuedMessages.firstIndex(where: { $0["id"] as? String == params["messageId"] as? String }) else { return nil }
            let row = queuedMessages.remove(at: index)
            if method == "agent.sendQueuedMessageNow", let messageId = row["id"] as? String, let content = row["content"] as? String {
                sentMessages.append(Self.message(id: messageId, role: "user", blocks: [DemoFixtures.textBlock(content)]))
            }
            return ["success": true, "queued": false]
        default: return nil
        }
    }

    /// Called after response mutation and before its acknowledgement is
    /// returned, exercising the live router's normal early-push buffering.
    func subscriptionPush(for method: String, params: [String: Any]) -> SubscriptionPush? {
        guard params["agentId"] as? String == Self.agentId,
              ["chat.subscribe", "agent.sendMessage", "agent.sendQueuedMessageNow", "agent.stop"].contains(method) else { return nil }
        if method != "chat.subscribe" { sequence += 1 }
        return SubscriptionPush(
            subscriptionId: DemoFixtures.chatSubscriptionId(agentId: Self.agentId),
            seq: sequence,
            conversationSnapshot: messages,
            metadata: ["truncated": historyIsTruncated, "totalMessages": totalMessageCount, "isResponding": isStreaming]
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
