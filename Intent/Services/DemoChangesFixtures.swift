import Foundation

enum DemoChangesFixtures {
    static let commitHash = "a12bc34de56f789012345678901234567890abcdef"

    static func response(for method: String, params: [String: Any]) -> Any? {
        if let response = DemoChangesRootFixtures.response(for: method, params: params) { return response }
        switch method {
        case "git.status":
            return [
                "files": [
                    ["path": "Sources/Analytics.swift", "status": "M", "staged": false],
                    ["path": "Sources/Analytics/Events.swift", "status": "M", "staged": false],
                    ["path": "Tests/AnalyticsTests.swift", "status": "M", "staged": true]
                ]
            ]
        case "file-tracking.getChanges":
            let changes = [
                change(path: "Sources/Analytics.swift", stage: "unstaged"),
                change(path: "Sources/Analytics/Events.swift", stage: "unstaged"),
                change(path: "Sources/report.py", stage: "unstaged"),
                change(path: "Sources/collector.go", stage: "unstaged"),
                change(path: "Config/analytics.json", stage: "unstaged"),
                change(path: "Config/analytics.yaml", stage: "unstaged"),
                change(path: "Web/collector.ts", stage: "unstaged"),
                change(path: "Web/dashboard.css", stage: "unstaged"),
                change(path: "Scripts/report.sh", stage: "unstaged"),
                change(path: "Tests/AnalyticsTests.swift", stage: "staged")
            ]
            return [
                "changes": changes,
                "truncated": false, "totalCount": changes.count
            ]
        case "file-tracking.loadCommits":
            return [
                "commits": [
                    [
                        "hash": commitHash, "message": "feat: add usage analytics", "author": "Analytics Agent",
                        "date": "2026-09-27T10:00:00Z", "agentId": "demo-analytics-agent", "isPushed": false
                    ]
                ],
                "boundarySha": "base", "nextToken": NSNull()
            ]
        case "git.diffs":
            return workingDiff(params: params)
        case "git.commitDetails":
            return [
                "commitHash": commitHash,
                "fileDetails": DemoDiffFixtures.files.map { file in
                    ["path": file.path, "additions": file.additions, "deletions": file.deletions]
                }
            ]
        case "git.branchDiff":
            let paths = params["paths"] as? [String] ?? []
            return DemoDiffFixtures.files.filter { paths.contains($0.path) }.map { file in
                ["file": file.path, "oldContent": file.old, "newContent": file.new]
            }
        case "events.subscribe" where (params["replaceGroup"] as? String)?.hasPrefix("ios-changes-") == true:
            return ["subscriptionId": UUID().uuidString]
        default:
            return nil
        }
    }

    private static func workingDiff(params: [String: Any]) -> [[String: Any]] {
        guard let file = DemoDiffFixtures.files.first(where: { $0.path == params["path"] as? String }) else { return [] }
        return [["path": file.path, "hunks": file.wireHunks]]
    }

    private static func change(path: String, stage: String) -> [String: Any] {
        let file = DemoDiffFixtures.files.first { $0.path == path }
        return [
            "id": "\(stage):\(path)", "file": "/workspace/\(path)", "relativePath": path,
            "stage": stage, "status": "modified",
            "stats": ["additions": file?.additions ?? 0, "deletions": file?.deletions ?? 0],
            "attribution": ["agent": ["agentId": "demo-analytics-agent", "agentName": "Analytics Agent"]]
        ]
    }
}
