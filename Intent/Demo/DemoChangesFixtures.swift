#if DEBUG
import Foundation

enum DemoChangesFixtures {
    static let commitHash = "a12bc34de56f789012345678901234567890abcdef"
    private static let testSource = "import Testing\n\n@Test func recordsUsage() {\n    #expect(Analytics().count == 1)\n}\n"
    private static let testLineCount = testSource.split(separator: "\n", omittingEmptySubsequences: false).count - 1
    private static let longCommitLineCount = 80
    private static var usesLongCommit: Bool { LaunchOptions.current.contains("--demo-long-commit") }
    static let largeDiffArgumentPrefix = "--demo-large-diff="
    private static let largeDiffLongLineInterval = 25
    private static let largeDiffLongLineEntries = 24
    /// Each run of six lines is three context lines, one deletion and two additions.
    private static let largeDiffPatternLength = 6
    private static let largeDiffContextLines = 3
    /// Changed lines in every demo file diff, for measuring large diffs (`--demo-large-diff=2000`).
    static var largeDiffLineCount: Int? { largeDiffLineCount(from: LaunchOptions.current.arguments) }

    static func largeDiffLineCount(from arguments: [String]) -> Int? {
        guard let argument = arguments.last(where: { $0.hasPrefix(largeDiffArgumentPrefix) }),
              let count = Int(argument.dropFirst(largeDiffArgumentPrefix.count)), count > 0 else { return nil }
        return count
    }

    /// Swift-like source with a long line every 25 lines so horizontal scrolling matters.
    static func largeDiffSource(lineCount: Int, prefix: String) -> String {
        (1...max(lineCount, 1)).map { index in
            index.isMultiple(of: largeDiffLongLineInterval)
                ? "    let \(prefix)\(index) = [\((0..<largeDiffLongLineEntries).map { "\"entry\(index)_\($0)\"" }.joined(separator: ", "))]"
                : "    let \(prefix)\(index) = compute(\(index), label: \"\(prefix) line \(index)\")"
        }.joined(separator: "\n") + "\n"
    }

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
                    "path": "Sources/Analytics.swift",
                    "additions": largeDiffLineCount ?? (usesLongCommit ? longCommitLineCount : 1),
                    "deletions": usesLongCommit || largeDiffLineCount != nil ? 0 : 1
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
        if let largeDiffLineCount, !path.hasPrefix("Tests/") {
            return [["file": path, "oldContent": "", "newContent": largeDiffSource(lineCount: largeDiffLineCount, prefix: "value")]]
        }
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
        if let largeDiffLineCount {
            return [["path": params["path"] as? String ?? "", "hunks": [largeHunk(lineCount: largeDiffLineCount)]]]
        }
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

    /// Repeating runs of context, deletion and additions totalling `lineCount` lines.
    private static func largeHunk(lineCount: Int) -> [String: Any] {
        let source = largeDiffSource(lineCount: lineCount, prefix: "value").split(separator: "\n").map(String.init)
        var oldNumber = 1
        var newNumber = 1
        var lines: [[String: Any]] = []
        for (index, content) in source.enumerated() {
            let position = index % largeDiffPatternLength
            if position < largeDiffContextLines {
                lines.append(["type": "Context", "content": content, "oldNumber": oldNumber, "newNumber": newNumber])
                oldNumber += 1
                newNumber += 1
            } else if position == largeDiffContextLines {
                lines.append(["type": "Deletion", "content": content, "oldNumber": oldNumber])
                oldNumber += 1
            } else {
                lines.append(["type": "Addition", "content": content, "newNumber": newNumber])
                newNumber += 1
            }
        }
        return [
            "oldStart": 1, "oldLines": oldNumber - 1, "newStart": 1, "newLines": newNumber - 1,
            "lines": lines
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
