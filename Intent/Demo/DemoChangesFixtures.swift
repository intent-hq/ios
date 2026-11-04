#if DEBUG
import Foundation

enum DemoChangesFixtures {
    static let commitHash = "a12bc34de56f789012345678901234567890abcdef"
    private static let testSource = "import Testing\n\n@Test func recordsUsage() {\n    #expect(Analytics().count == 1)\n}\n"
    private static let testLineCount = testSource.split(separator: "\n", omittingEmptySubsequences: false).count - 1
    private static let longCommitLineCount = 80
    private static var usesLongCommit: Bool { ProcessInfo.processInfo.arguments.contains("--demo-long-commit") }

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
            return commitDetails
        case "git.branchDiff":
            return commitDiff(params: params)
        case "events.subscribe" where (params["replaceGroup"] as? String)?.hasPrefix("ios-changes-") == true:
            return ["subscriptionId": UUID().uuidString]
        default:
            return nil
        }
    }

    private static var commitDetails: [String: Any] {
        [
            "commitHash": commitHash,
            "fileDetails": [
                [
                    "path": "Sources/Analytics.swift", "additions": usesLongCommit ? longCommitLineCount : 1,
                    "deletions": usesLongCommit ? 0 : 1
                ],
                [
                    "path": "Tests/AnalyticsTests.swift", "additions": usesLongCommit ? longCommitLineCount : testLineCount,
                    "deletions": 0
                ]
            ]
        ]
    }

    private static func commitDiff(params: [String: Any]) -> [[String: Any]] {
        let path = (params["paths"] as? [String])?.first ?? ""
        if usesLongCommit {
            let name = path.hasPrefix("Tests/") ? "testValue" : "value"
            let source = (1...longCommitLineCount).map { "let \(name)\($0) = \($0)" }.joined(separator: "\n") + "\n"
            return [["file": path, "oldContent": "", "newContent": source]]
        }
        if path.hasPrefix("Tests/") {
            return [["file": path, "oldContent": "", "newContent": testSource]]
        }
        let source = "import Foundation\n\nstruct Analytics {\n    let count = 0\n}\n"
        let updated = source.replacingOccurrences(of: "count = 0", with: "count = 1")
        return [["file": path, "oldContent": source, "newContent": updated]]
    }

    private static func workingDiff(params: [String: Any]) -> [[String: Any]] {
        let staged = params["staged"] as? Bool ?? false
        return [
            [
                "path": params["path"] as? String ?? "",
                "hunks": [
                    [
                        "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                        "lines": [
                            ["type": "Deletion", "content": "let enabled = false", "oldNumber": 1],
                            ["type": "Addition", "content": staged ? "let staged = true" : "let enabled = true", "newNumber": 1]
                        ]
                    ]
                ]
            ]
        ]
    }

    private static func change(path: String, stage: String) -> [String: Any] {
        [
            "id": "\(stage):\(path)", "file": "/workspace/\(path)", "relativePath": path,
            "stage": stage, "status": "modified", "stats": ["additions": 1, "deletions": 1],
            "attribution": ["agent": ["agentId": "demo-analytics-agent", "agentName": "Analytics Agent"]]
        ]
    }
}
#endif
