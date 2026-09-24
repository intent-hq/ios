import Foundation

extension DemoFixtures {
    static let assistantAgentId = "demo-agent-assistant"

    static var assistantAgents: [[String: Any]] {
        [[
            "id": assistantAgentId,
            "name": "Assistant",
            "workspaceId": Workspace.chiefWorkspaceId,
            "status": "idle",
            "updatedAt": "2026-09-24T10:00:00Z",
            "metadata": ["specialist": "chief-of-staff"]
        ]]
    }

    static var assistantMessages: [[String: Any]] {
        [[
            "id": "demo-assistant-message",
            "role": "assistant",
            "contentBlocks": [[
                "type": "text",
                "text": "I can help you plan and follow up across your workspaces. What would you like to work on?"
            ]],
            "timestamp": "2026-09-24T10:00:00Z"
        ]]
    }
}
