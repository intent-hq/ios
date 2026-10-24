import Foundation

/// Demo `github.pulls.search` results over the demo workspaces' repositories.
/// Honors the batch, `state`, `filter` and `query` parameters.
enum DemoPullRequestFixtures {
    private struct Pull {
        let repo: String
        let number: Int
        let title: String
        let author: String
        let minutesAgo: Double
        var state = "open"
        var draft = false
        var merged = false
        var mine = false
        var reviewRequested = false
    }

    private static let owner = "nova-labs"

    private static let pulls: [Pull] = [
        Pull(repo: "console", number: 482, title: "feat: usage analytics dashboard with CSV export", author: "octocat", minutesAgo: 25, mine: true),
        Pull(repo: "gateway", number: 311, title: "fix: back off websocket reconnects with jitter", author: "mona", minutesAgo: 48, reviewRequested: true),
        Pull(repo: "mobile", number: 157, title: "Dark mode tokens for settings screens", author: "hubot", minutesAgo: 190, draft: true, mine: true),
        Pull(repo: "billing", number: 904, title: "test: deflake payment webhook retries", author: "mona", minutesAgo: 340, reviewRequested: true),
        Pull(repo: "console", number: 479, title: "chore: upgrade chart library to v5", author: "dependabot", minutesAgo: 1_500),
        Pull(repo: "gateway", number: 305, title: "feat: per-tenant rate limit overrides", author: "octocat", minutesAgo: 4_300, mine: true),
        Pull(repo: "console", number: 470, title: "fix: keep filters when paging the audit log", author: "hubot", minutesAgo: 2_900, state: "closed", merged: true),
        Pull(repo: "billing", number: 899, title: "Prototype invoice PDF renderer", author: "octocat", minutesAgo: 7_200, state: "closed", mine: true)
    ]

    static func response(for method: String, params: [String: Any]) -> Any? {
        guard method == "github.pulls.search" else { return nil }
        var repos: Set<String> = []
        if let repo = params["repo"] as? String { repos.insert(repo) }
        for extra in params["repos"] as? [[String: Any]] ?? [] {
            if let repo = extra["repo"] as? String { repos.insert(repo) }
        }
        let closed = params["state"] as? String == "closed"
        let filter = params["filter"] as? String ?? "all"
        let query = (params["query"] as? String)?.lowercased() ?? ""
        let rows = pulls.filter { pull in
            repos.contains(pull.repo)
                && (pull.state == "closed") == closed
                && (filter != "created" || pull.mine)
                && (filter != "review-requested" || pull.reviewRequested)
                && (filter != "assigned" || pull.mine)
                && (query.isEmpty || pull.title.lowercased().contains(query))
        }
        return ["pulls": rows.map(wire)]
    }

    private static func wire(_ pull: Pull) -> [String: Any] {
        [
            "number": pull.number,
            "title": pull.title,
            "htmlUrl": "https://github.com/\(owner)/\(pull.repo)/pull/\(pull.number)",
            "state": pull.state,
            "draft": pull.draft,
            "merged": pull.merged,
            "user": ["login": pull.author],
            "updatedAt": DemoFixtures.iso(minutesAgo: pull.minutesAgo),
            "owner": owner,
            "repo": pull.repo
        ]
    }
}
