import Foundation

extension DemoFixtures {
    static let assistantAgentId = "demo-agent-assistant"
    private static let assistantHistoryCount = 30
    private static var createdAssistantAgents: [[String: Any]] = []
    private static var proposalOutcome: String?
    private static var assistantListFailed = false

    static var assistantAgents: [[String: Any]] {
        if ProcessInfo.processInfo.arguments.contains("--demo-assistant-empty") { return createdAssistantAgents }
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
                "metadata": assistantMetadata
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

    /// Exercise the Assistant's real loading, retry and first-conversation flow.
    static func assistantListGate(for method: String, params: [String: Any]) -> ResponseGate? {
        guard method == "agent.list", params["workspaceId"] as? String == Workspace.chiefWorkspaceId else { return nil }
        return triggerFile(from: ProcessInfo.processInfo.arguments, prefix: "--demo-assistant-list-trigger-file=").map(ResponseGate.triggerFile)
    }

    static func assistantListResponse() -> [String: Any] {
        if ProcessInfo.processInfo.arguments.contains("--demo-assistant-list-retry"), !assistantListFailed {
            assistantListFailed = true
            return [:]
        }
        return ["agents": assistantAgents]
    }

    static func streamAssistantPromptsIfRequested(in store: ConversationStore) async {
        await streamWorkspaceLinksIfRequested(in: store)
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

    private static func streamWorkspaceLinksIfRequested(in store: ConversationStore) async {
        let prefix = "--demo-workspace-stream-trigger="
        guard DemoMode.isEnabled, store.agentId == assistantAgentId,
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return }
        let trigger = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)))
        store.messages = [
            ConversationMessage(
                id: "workspace-stream",
                role: .assistant,
                contentBlocks: [ContentBlock(id: "text", type: .text, text: "Workspace links are loading.\n\n@@@work")],
                streamingState: .streaming
            )
        ]
        store.isStreaming = true
        do {
            try await wait(for: .triggerFile(trigger))
            try Task.checkCancellation()
        } catch { return }
        var message = store.messages[0]
        message.contentBlocks.append(ContentBlock(id: "tail", type: .text, text: "space\n\(longConversationWorkspaceId)\n@@@"))
        message.streamingState = .complete
        store.messages = [message]
        store.isStreaming = false
    }

    private static var assistantReplyBlocks: [[String: Any]] {
        if ProcessInfo.processInfo.arguments.contains("--demo-assistant-workspace-proposal") { return workspaceProposalReplyBlocks }
        if ProcessInfo.processInfo.arguments.contains("--demo-assistant-proposal") { return proposalReplyBlocks }
        if ProcessInfo.processInfo.arguments.contains("--demo-assistant-workspace-links") {
            return [
                ["type": "text", "text": "Open this workspace.\n\n@@@work"],
                ["type": "text", "text": "space\n\(longConversationWorkspaceId)\nmissing-workspace\n@@@\n\nReady when you are."]
            ]
        }
        return [["type": "text", "text": "I can help you plan and follow up across your workspaces. What would you like to work on?"]]
    }

    private static var assistantMetadata: [String: Any] {
        guard ProcessInfo.processInfo.arguments.contains("--demo-assistant-proposal")
            || ProcessInfo.processInfo.arguments.contains("--demo-assistant-workspace-proposal") else { return ["specialist": "chief-of-staff"] }
        if let proposalOutcome { return ["proposalResolutions": ["demo-proposal": proposalOutcome]] }
        return ["pendingProposals": [["proposalId": "demo-proposal", "messageId": "demo-assistant-message"]]]
    }

    private static var proposalReplyBlocks: [[String: Any]] {
        let proposal: [String: Any] = [
            "kind": "bulk-op", "applyToolCallId": "demo-proposal",
            "payload": ["operation": "workspace.bulkArchive", "ids": [longConversationWorkspaceId]],
            "preview": [
                "title": "Archive selected workspaces", "summary": "Review before archiving.", "applyLabel": "Archive",
                "bulkItems": [["id": longConversationWorkspaceId, "title": "Deflake payment integration tests", "selected": true]]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: proposal), let json = String(data: data, encoding: .utf8) else { return [] }
        return [
            ["type": "text", "text": "@@@workspace\n\(longConversationWorkspaceId)\n@@@"],
            ["type": "resource", "resource": ["mimeType": "application/vnd.intent.proposal+json", "text": json]]
        ]
    }

    static func proposalResponse(for method: String, params: [String: Any]) -> Any? {
        if let response = workspaceProposalResponse(for: method, params: params) { return response }
        guard ProcessInfo.processInfo.arguments.contains("--demo-assistant-proposal")
            || ProcessInfo.processInfo.arguments.contains("--demo-assistant-workspace-proposal") else { return nil }
        switch method {
        case "workspace.archive": return ["workspace": ["id": params["workspaceId"] ?? ""]]
        case "agent.resolveProposal":
            proposalOutcome = params["outcome"] as? String
            return ["success": true, "outcome": proposalOutcome ?? "dismissed"] as [String: Any]
        default: return nil
        }
    }
}
