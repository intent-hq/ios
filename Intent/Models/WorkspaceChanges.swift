import Foundation

/// File-tracking rows retain their stage so a partly staged file appears in both sections.
struct WorkspaceChange: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let stage: String
    let status: String
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let agentName: String?
    var hasLineStats = true

    static func parse(_ dictionary: [String: Any]) -> Self? {
        guard let id = dictionary["id"] as? String, !id.isEmpty,
              let path = dictionary["relativePath"] as? String, !path.isEmpty,
              let stage = dictionary["stage"] as? String,
              stages.contains(stage),
              let stats = dictionary["stats"] as? [String: Any],
              let additions = stats["additions"] as? Int, additions >= 0,
              let deletions = stats["deletions"] as? Int, deletions >= 0 else { return nil }
        let attribution = dictionary["attribution"] as? [String: Any]
        let agent = attribution?["agent"] as? [String: Any]
        return Self(
            id: id,
            path: path,
            stage: stage,
            status: dictionary["status"] as? String ?? "modified",
            additions: additions,
            deletions: deletions,
            isBinary: stats["binary"] as? Bool ?? false,
            agentName: agent?["agentName"] as? String
        )
    }

    private static let stages: Set<String> = [
        "unstaged", "staged", "committed", "pushed", "pull_request", "merged", "trunk"
    ]

    static func parseStatus(_ dictionary: [String: Any], rootId: String) -> Self? {
        guard let path = dictionary["path"] as? String, !path.isEmpty,
              let rawStatus = dictionary["status"] as? String,
              let status = statusNames[rawStatus],
              let staged = dictionary["staged"] as? Bool else { return nil }
        let stage = staged ? "staged" : "unstaged"
        return Self(
            id: "\(rootId):\(stage):\(path)",
            path: path,
            stage: stage,
            status: status,
            additions: 0,
            deletions: 0,
            isBinary: false,
            agentName: nil,
            hasLineStats: false
        )
    }

    private static let statusNames = [
        "M": "modified", "A": "added", "D": "deleted", "R": "renamed",
        "C": "copied", "?": "untracked", "!": "ignored"
    ]
}

/// Metadata-only commit rows; per-file diffs are fetched when opening the commit.
struct WorkspaceCommit: Identifiable, Equatable, Sendable {
    var id: String { hash }
    let hash: String
    let message: String
    let author: String
    let date: String
    let agentId: String?
    let isPushed: Bool
    var isPushedKnown = true

    static func parse(_ dictionary: [String: Any]) -> Self? {
        guard let hash = dictionary["hash"] as? String, !hash.isEmpty,
              let message = dictionary["message"] as? String,
              let author = dictionary["author"] as? String,
              let date = dictionary["date"] as? String,
              let isPushed = dictionary["isPushed"] as? Bool else { return nil }
        return Self(
            hash: hash,
            message: message,
            author: author,
            date: date,
            agentId: dictionary["agentId"] as? String,
            isPushed: isPushed
        )
    }

    static func parseSummary(_ dictionary: [String: Any]) -> Self? {
        var attributed = dictionary
        attributed["isPushed"] = false
        guard var commit = parse(attributed) else { return nil }
        commit.isPushedKnown = false
        return commit
    }
}

struct WorkspaceGitRoot: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let displayName: String
    let branch: String?
    let registeredCommitSha: String?

    static func parse(_ dictionary: [String: Any]) -> Self? {
        guard let id = dictionary["id"] as? String, !id.isEmpty,
              let path = dictionary["path"] as? String, !path.isEmpty else { return nil }
        let repoName = dictionary["repoName"] as? String
        return Self(
            id: id,
            path: path,
            displayName: repoName.flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: path).lastPathComponent,
            branch: dictionary["branch"] as? String,
            registeredCommitSha: (dictionary["registeredCommitSha"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func parseList(_ result: Any) throws -> [Self] {
        guard let dictionary = result as? [String: Any],
              let rows = dictionary["gitRoots"] as? [[String: Any]] else {
            throw WorkspaceChangesDecodingError.invalidRepositories
        }
        let roots = rows.compactMap(Self.parse)
        guard roots.count == rows.count, Set(roots.map(\.id)).count == roots.count else {
            throw WorkspaceChangesDecodingError.invalidRepositories
        }
        return roots
    }
}

enum WorkspaceChangesDecodingError: LocalizedError {
    case invalidChanges
    case invalidCommits
    case invalidRepositories

    var errorDescription: String? {
        switch self {
        case .invalidChanges: "The server returned an invalid list of changed files."
        case .invalidCommits: "The server returned an invalid commit history."
        case .invalidRepositories: "The server returned an invalid repository list."
        }
    }
}

struct WorkspaceChangesSnapshot {
    let changes: [WorkspaceChange]
    let isTruncated: Bool

    init(_ result: Any) throws {
        guard let dictionary = result as? [String: Any],
              let rows = dictionary["changes"] as? [[String: Any]],
              let truncated = dictionary["truncated"] as? Bool else {
            throw WorkspaceChangesDecodingError.invalidChanges
        }
        let changes = rows.compactMap(WorkspaceChange.parse)
        guard changes.count == rows.count else { throw WorkspaceChangesDecodingError.invalidChanges }
        self.changes = changes
        isTruncated = truncated
    }

    init(_ result: Any, rootId: String) throws {
        guard let dictionary = result as? [String: Any],
              let rows = dictionary["files"] as? [[String: Any]] else {
            throw WorkspaceChangesDecodingError.invalidChanges
        }
        let changes = rows.compactMap { WorkspaceChange.parseStatus($0, rootId: rootId) }
        guard changes.count == rows.count else { throw WorkspaceChangesDecodingError.invalidChanges }
        self.changes = changes
        isTruncated = dictionary["filesTruncated"] as? Bool ?? false
    }
}

struct WorkspaceCommitPage {
    let commits: [WorkspaceCommit]
    let boundarySha: String?
    let nextToken: String?

    init(_ result: Any) throws {
        guard let dictionary = result as? [String: Any],
              let rows = dictionary["commits"] as? [[String: Any]] else {
            throw WorkspaceChangesDecodingError.invalidCommits
        }
        let commits = rows.compactMap(WorkspaceCommit.parse)
        guard commits.count == rows.count else { throw WorkspaceChangesDecodingError.invalidCommits }
        self.commits = commits
        boundarySha = try Self.optionalString(dictionary["boundarySha"])
        nextToken = try Self.optionalString(dictionary["nextToken"])
    }

    init(_ result: Any, root: WorkspaceGitRoot) throws {
        guard let dictionary = result as? [String: Any],
              let rows = dictionary["items"] as? [[String: Any]] else {
            throw WorkspaceChangesDecodingError.invalidCommits
        }
        let commits = rows.compactMap(WorkspaceCommit.parseSummary)
        guard commits.count == rows.count else { throw WorkspaceChangesDecodingError.invalidCommits }
        boundarySha = root.registeredCommitSha
        if let boundary = commits.firstIndex(where: { $0.hash == root.registeredCommitSha }) {
            self.commits = Array(commits.prefix(boundary))
            nextToken = nil
        } else {
            self.commits = commits
            nextToken = try Self.optionalString(dictionary["nextToken"])
        }
    }

    private static func optionalString(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String, !string.isEmpty else {
            throw WorkspaceChangesDecodingError.invalidCommits
        }
        return string
    }
}
