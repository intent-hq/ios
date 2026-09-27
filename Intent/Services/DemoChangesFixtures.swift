import Foundation

enum DemoChangesFixtures {
    static let commitHash = "a12bc34de56f789012345678901234567890abcdef"

    static func response(for method: String, params: [String: Any]) -> Any? {
        switch method {
        case "file-tracking.getChanges":
            return [
                "changes": [change(path: "Sources/Analytics.swift", stage: "unstaged"),
                            change(path: "Tests/AnalyticsTests.swift", stage: "staged")],
                "truncated": false, "totalCount": 2
            ]
        case "file-tracking.loadCommits":
            return ["commits": [[
                "hash": commitHash, "message": "feat: add usage analytics", "author": "Analytics Agent",
                "date": "2026-09-27T10:00:00Z", "agentId": "demo-analytics-agent", "isPushed": false
            ]], "boundarySha": "base", "nextToken": NSNull()]
        case "git.diffs":
            let staged = params["staged"] as? Bool ?? false
            return [["path": params["path"] as? String ?? "", "hunks": [[
                "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                "lines": [
                    ["type": "Deletion", "content": "let enabled = false", "oldNumber": 1],
                    ["type": "Addition", "content": staged ? "let staged = true" : "let enabled = true", "newNumber": 1]
                ]
            ]]]]
        case "git.commitDetails":
            return ["commitHash": commitHash, "fileDetails": [
                ["path": "Sources/Analytics.swift", "additions": 1, "deletions": 1],
                ["path": "Tests/AnalyticsTests.swift", "additions": 1, "deletions": 0]
            ]]
        case "git.branchDiff":
            let path = (params["paths"] as? [String])?.first ?? ""
            return [["file": path, "oldContent": "let count = 0\n", "newContent": "let count = 1\n"]]
        case "events.subscribe" where (params["replaceGroup"] as? String)?.hasPrefix("ios-changes-") == true:
            return ["subscriptionId": UUID().uuidString]
        default:
            return nil
        }
    }

    private static func change(path: String, stage: String) -> [String: Any] {
        ["id": "\(stage):\(path)", "file": "/workspace/\(path)", "relativePath": path,
         "stage": stage, "status": "modified", "stats": ["additions": 1, "deletions": 1],
         "attribution": ["agent": ["agentId": "demo-analytics-agent", "agentName": "Analytics Agent"]]]
    }
}
