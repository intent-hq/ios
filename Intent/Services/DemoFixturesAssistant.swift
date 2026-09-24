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

    static var assistantMessages: [[String: Any]] {
        [
            [
                "id": "demo-assistant-message",
                "role": "assistant",
                "contentBlocks": [
                    [
                        "type": "text",
                        "text": "I can help you plan and follow up across your workspaces. What would you like to work on?"
                    ]
                ],
                "timestamp": "2026-09-24T10:00:00Z"
            ]
        ]
    }
}
