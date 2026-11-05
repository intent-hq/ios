#if DEBUG
import Foundation

extension DemoFixtures {
    private static var proposedWorkspace: [String: Any] = [:]
    private static var proposedWorkspaceRequest: AnyCodable?

    static var workspaceProposalReplyBlocks: [[String: Any]] {
        let proposal: [String: Any] = [
            "kind": "workspace-create", "applyToolCallId": "demo-proposal",
            "payload": [
                "operation": "workspace.create",
                "params": [
                    "title": "Investigate Mermaid tests", "repositoryPath": "/repos/intent", "baseRef": "main",
                    "idempotencyKey": "demo-workspace-proposal",
                    "initialAgent": ["prompt": "Investigate the failing Mermaid tests.", "specialist": "implementor"]
                ]
            ],
            "preview": [
                "title": "Create workspace: Investigate Mermaid tests",
                "summary": "Review this follow-up workspace before creating it.",
                "workspaceCreate": ["mode": "sibling"]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: proposal),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return [["type": "resource", "resource": ["mimeType": "application/vnd.intent.proposal+json", "text": json]]]
    }

    static func workspaceProposalResponse(for method: String, params: [String: Any]) -> Any? {
        guard ProcessInfo.processInfo.arguments.contains("--demo-assistant-workspace-proposal") else { return nil }
        if method == "workspace.list", !proposedWorkspace.isEmpty { return ["workspaces": workspaces + [proposedWorkspace]] }
        guard method == "workspace.create" else { return nil }
        if let proposedWorkspaceRequest {
            guard proposedWorkspaceRequest == AnyCodable(params), !proposedWorkspace.isEmpty else { return [String: Any]() }
            return ["workspace": proposedWorkspace]
        }
        proposedWorkspaceRequest = AnyCodable(params)
        proposedWorkspace = [
            "id": "demo-proposed-workspace", "title": params["title"] as? String ?? "Follow-up workspace",
            "repositoryPath": params["repositoryPath"] ?? "", "status": "active"
        ]
        if ProcessInfo.processInfo.arguments.contains("--demo-workspace-proposal-retry") { return [String: Any]() }
        return ["workspace": proposedWorkspace]
    }
}
#endif
