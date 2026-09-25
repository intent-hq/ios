import Foundation

extension DemoFixtures {
    static let assistantAgentId = "demo-agent-assistant"
    private static let assistantHistoryCount = 30
    private static var createdAssistantAgents: [[String: Any]] = []

    static var assistantAgents: [[String: Any]] {
        let history: [[String: Any]] = ProcessInfo.processInfo.arguments.contains("--demo-assistant-history")
            ? (0..<assistantHistoryCount).map { index in
                [
                    "id": "demo-assistant-history-\(index)",
                    "name": "Earlier conversation \(index)",
                    "workspaceId": Workspace.chiefWorkspaceId,
                    "status": "idle",
                    "updatedAt": "2026-09-23T10:00:00Z"
                ]
            } : []
        return [
            [
                "id": assistantAgentId,
                "name": "Assistant",
                "workspaceId": Workspace.chiefWorkspaceId,
                "status": "idle",
                "updatedAt": "2026-09-24T10:00:00Z",
                "metadata": ["specialist": "chief-of-staff"]
            ]
        ] + history + createdAssistantAgents
    }

    static func createAssistantAgent() -> [String: Any] {
        let agent: [String: Any] = [
            "id": "demo-assistant-created-\(UUID().uuidString)",
            "name": "Assistant",
            "workspaceId": Workspace.chiefWorkspaceId,
            "status": "idle",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "metadata": ["specialist": "chief-of-staff"]
        ]
        createdAssistantAgents.append(agent)
        return ["agent": agent]
    }

    static func streamAssistantPromptsIfRequested(in store: ConversationStore) async {
        let prefix = "--demo-assistant-prompts-trigger-file="
        guard DemoMode.isEnabled, store.agentId == assistantAgentId,
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return }
        let trigger = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)))
        let opening = "Hey bro — what’s on your mind?\n\n<!-- suggested-prompts\n"
        let prompts = "Show me what needs my attention.\nHelp me start something new."
        let split = ProcessInfo.processInfo.arguments.contains("--demo-assistant-prompts-split")
        let blocks = split ? [
            ContentBlock(id: "reply", type: .text, text: opening),
            ContentBlock(id: "prompts", type: .text, text: prompts)
        ] : [ContentBlock(id: "reply", type: .text, text: opening + prompts)]
        store.messages = [
            ConversationMessage(
                id: "demo-streaming-assistant",
                role: .assistant,
                contentBlocks: blocks,
                streamingState: .streaming
            )
        ]
        store.isStreaming = true
        do {
            try await wait(for: .triggerFile(trigger))
            try Task.checkCancellation()
        } catch { return }
        var message = store.messages[0]
        let lastIndex = message.contentBlocks.count - 1
        message.contentBlocks[lastIndex].text = (message.contentBlocks[lastIndex].resolvedText ?? "") + "\n-->"
        message.streamingState = .complete
        store.messages = [message]
        store.isStreaming = false
    }

    static var assistantMessages: [[String: Any]] {
        [
            [
                "id": "demo-assistant-message",
                "role": "assistant",
                "contentBlocks": assistantReplyBlocks,
                "timestamp": "2026-09-24T10:00:00Z"
            ]
        ]
    }

    private static var assistantReplyBlocks: [[String: Any]] {
        if ProcessInfo.processInfo.arguments.contains("--demo-assistant-workspace-links") {
            return [
                ["type": "text", "text": "Open this workspace.\n\n@@@work"],
                ["type": "text", "text": "space\n\(longConversationWorkspaceId)\nmissing-workspace\n@@@\n\nReady when you are."]
            ]
        }
        return [["type": "text", "text": "I can help you plan and follow up across your workspaces. What would you like to work on?"]]
    }
}
