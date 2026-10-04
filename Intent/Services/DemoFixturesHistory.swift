import Foundation

extension DemoFixtures {
    /// Opt-in varied-height pages with deterministic transport gates; ordinary
    /// demo and screenshot fixtures stay intact.
    static var usesHistoryPages: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo-history-pages")
    }

    private static let historyMessageCount = 30
    private static let historyPageSize = 10
    private static let historyParagraphVariants = 3
    private static let historyCursorPrefix = "history-before-"

    static func conversationResponse(params: [String: Any]) -> [String: Any] {
        if usesHistoryPages, params["agentId"] as? String == longConversationAgentId {
            return historyPage(params: params)
        }
        let messages = transcriptMessages(agentId: params["agentId"] as? String)
        return ["messages": messages, "truncated": false, "totalMessages": messages.count]
    }

    static func historySubscriptionPush(params: [String: Any]) -> SubscriptionPush? {
        guard usesHistoryPages, params["agentId"] as? String == longConversationAgentId else { return nil }
        var page = historyPage(params: params)
        guard let messages = page.removeValue(forKey: "messages") as? [[String: Any]] else { return nil }
        return SubscriptionPush(subscriptionId: chatSubscriptionId(agentId: longConversationAgentId), seq: 0, conversationSnapshot: messages, metadata: page)
    }

    private static func historyPage(params: [String: Any]) -> [String: Any] {
        let cursor = params["nextToken"] as? String
        if cursor != nil,
           let recovery = triggerFile(from: ProcessInfo.processInfo.arguments, prefix: "--demo-history-retry-trigger-file="),
           !FileManager.default.fileExists(atPath: recovery.path) {
            return ["error": "Earlier messages are temporarily unavailable"]
        }
        let end = cursor.flatMap { Int($0.dropFirst(historyCursorPrefix.count)) } ?? historyMessageCount
        let start = max(0, end - historyPageSize)
        return [
            "messages": (start..<end).map(historyMessage),
            "totalMessages": historyMessageCount,
            "truncated": start > 0,
            "nextToken": start > 0 ? historyCursorPrefix + String(start) : NSNull()
        ]
    }

    static func historyResponseGate(for method: String, params: [String: Any]) -> ResponseGate? {
        guard usesHistoryPages, method == "agent.getConversation",
              params["agentId"] as? String == longConversationAgentId,
              params["nextToken"] as? String == historyCursorPrefix + String(historyMessageCount - historyPageSize)
        else { return nil }
        return triggerFile(from: ProcessInfo.processInfo.arguments, prefix: "--demo-history-page-trigger-file=")
            .map(ResponseGate.triggerFile)
    }

    private static func historyMessage(_ index: Int) -> [String: Any] {
        let detail = "We checked the payment flow and kept the investigation notes available for the next review. "
        var text = "History message \(index + 1). " + String(repeating: detail, count: 1 + index % historyParagraphVariants)
        if index == historyMessageCount - 1 {
            text += "\n\n" + longConversationLastSentence + "\n\n"
                + (["<!-- suggested-prompts"] + longConversationSuggestedPrompts + ["-->"]).joined(separator: "\n")
        }
        return ["id": "history-message-\(index)", "role": "assistant", "contentBlocks": [textBlock(text)]]
    }
}
