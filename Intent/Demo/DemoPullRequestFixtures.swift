#if DEBUG
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

    // swiftlint:disable no_magic_numbers
    private static let pulls: [Pull] = [
        Pull(repo: "console", number: 482, title: "feat: usage analytics dashboard with CSV export", author: "octocat", minutesAgo: 25, mine: true),
        Pull(repo: "gateway", number: 311, title: "fix: back off websocket reconnects with jitter", author: "mona", minutesAgo: 48, reviewRequested: true),
        Pull(repo: "mobile", number: 157, title: "Dark mode tokens for settings screens", author: "hubot", minutesAgo: 190, draft: true, mine: true),
        Pull(repo: "billing", number: 904, title: "test: deflake payment webhook retries", author: "mona", minutesAgo: 340, reviewRequested: true),
        Pull(repo: "console", number: 479, title: "chore: upgrade chart library to v5", author: "dependabot", minutesAgo: 25 * 60),
        Pull(repo: "gateway", number: 305, title: "feat: per-tenant rate limit overrides", author: "octocat", minutesAgo: 72 * 60, mine: true),
        Pull(repo: "console", number: 470, title: "fix: keep filters when paging the audit log", author: "hubot", minutesAgo: 48 * 60, state: "closed", merged: true),
        Pull(repo: "billing", number: 899, title: "Prototype invoice PDF renderer", author: "octocat", minutesAgo: 120 * 60, state: "closed", mine: true)
    ]
    // swiftlint:enable no_magic_numbers

    static func response(for method: String, params: [String: Any]) -> Any? {
        if let detail = detailResponse(for: method, params: params) { return detail }
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
            "repo": pull.repo,
            "headRef": "feature/pr-\(pull.number)"
        ]
    }

    // MARK: - Detail

    private static func detailResponse(for method: String, params: [String: Any]) -> Any? {
        guard method.hasPrefix("github.pulls."), method != "github.pulls.search",
              let number = params["number"] as? Int,
              let pull = pulls.first(where: { $0.number == number }) else { return nil }
        switch method {
        case "github.pulls.get":
            var detail = wire(pull)
            detail["body"] = body(for: pull)
            detail["baseRef"] = "main"
            return ["pull": detail]
        case "github.pulls.checks":
            let names = ["SwiftLint", "iOS Build & Test", "iOS UI Tests", "visionOS Build"]
            let checks = names.map { ["name": $0, "state": pull.draft ? "pending" : "success", "url": "https://github.com/\(owner)/\(pull.repo)/actions"] }
            return ["headSha": "demo", "checks": checks, "requestedReviewers": pull.reviewRequested ? ["octocat"] : ["mona"]]
        case "github.pulls.reviews":
            let reviews: [[String: Any]] = pull.mine ? [["id": 1, "author": "mona", "state": "APPROVED"]] : []
            return ["reviews": reviews]
        case "github.pulls.files":
            return ["headSha": "demo", "truncated": false, "files": files]
        default:
            return nil
        }
    }

    private static func body(for pull: Pull) -> String {
        """
        ## Summary
        \(pull.title.prefix(1).uppercased() + pull.title.dropFirst()). This keeps the existing flow \
        and adds focused tests.

        ## What Changed
        - Add the `\(pull.repo)` changes behind a feature flag.
        - Update fixtures and **accessibility** labels.
        - Remove an obsolete migration path.
        """
    }

    // swiftlint:disable no_magic_numbers
    private static let files: [[String: Any]] = [
        [
            "filename": "Sources/Dashboard/UsageChart.swift", "status": "modified", "additions": 6, "deletions": 2,
            "patch": """
            @@ -12,6 +12,10 @@ struct UsageChart: View {
                 let points: [UsagePoint]
            -    var body: some View { Chart(points) { LineMark(x: .value("Day", $0.day), y: .value("Calls", $0.calls)) } }
            +    var body: some View {
            +        Chart(points) { point in
            +            LineMark(x: .value("Day", point.day), y: .value("Calls", point.calls))
            +        }
            +        .chartYAxis { AxisMarks(position: .leading) }
            +    }
             }
            """
        ],
        ["filename": "Sources/Dashboard/CSVExporter.swift", "status": "added", "additions": 42, "deletions": 0],
        ["filename": "Tests/DashboardTests/CSVExporterTests.swift", "status": "added", "additions": 28, "deletions": 0]
    ]
    // swiftlint:enable no_magic_numbers
}
#endif
