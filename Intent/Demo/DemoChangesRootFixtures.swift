#if DEBUG
import Foundation

enum DemoChangesRootFixtures {
    private static let rootId = "demo-ios-root"
    private static let commitHash = "b12bc34de56f789012345678901234567890abcdef"

    static func response(for method: String, params: [String: Any]) -> Any? {
        if method == "gitRoot.list" {
            return [
                "gitRoots": [
                    [
                        "id": rootId, "path": "/workspace/packages/ios", "repoName": "ios",
                        "source": "auto", "branch": "feat/analytics", "registeredCommitSha": "base-ios"
                    ]
                ]
            ]
        }
        guard params["gitRootId"] as? String == rootId else { return nil }
        switch method {
        case "git.status":
            return [
                "files": [
                    ["path": "Sources/Analytics.swift", "status": "M", "staged": false],
                    ["path": "Tests/MobileAnalyticsTests.swift", "status": "A", "staged": true]
                ],
                "filesTruncated": false
            ]
        case "git.commits":
            return commitPage
        case "git.diffs":
            return workingDiff(params: params)
        case "git.commitDetails":
            return [
                "commitHash": params["commitHash"] as? String ?? "", "date": "2026-09-27T10:00:00Z",
                "fileDetails": [["path": "Sources/Analytics.swift", "additions": 1, "deletions": 1]]
            ]
        case "git.showFile":
            let isParent = (params["ref"] as? String)?.hasSuffix("^") == true
            return ["content": isParent ? "let mobileCount = 0\n" : "let mobileCount = 1\n"]
        default:
            return nil
        }
    }

    private static var commitPage: [String: Any] {
        [
            "items": [
                [
                    "hash": commitHash, "message": "feat: add mobile analytics", "author": "Mobile Agent",
                    "date": "2026-09-27T11:00:00Z", "agentId": "demo-mobile-agent"
                ],
                ["hash": "base-ios", "message": "base", "author": "Developer", "date": "2026-09-26T10:00:00Z"]
            ],
            "nextToken": NSNull()
        ]
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
                            ["type": "Deletion", "content": "let mobile = false", "oldNumber": 1],
                            ["type": "Addition", "content": staged ? "let mobileStaged = true" : "let mobile = true", "newNumber": 1]
                        ]
                    ]
                ]
            ]
        ]
    }
}
#endif
