import Foundation

/// One row of the pull requests list: a lenient parse of a
/// `github.pulls.search` result (FE Home `PullWire` parity).
struct PullRequestListItem: Identifiable, Hashable {
    let owner: String
    let repo: String
    let number: Int
    let title: String
    let url: URL?
    let status: WorkspacePrPill.Status
    let author: String?
    let updatedAt: String?
    let headRef: String?

    /// Lowercased `owner/repo#number`, shared with workspace links.
    var id: String { Self.key(owner: owner, repo: repo, number: number) }

    static func key(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)".lowercased()
    }

    init(
        owner: String,
        repo: String,
        number: Int,
        title: String,
        url: URL? = nil,
        status: WorkspacePrPill.Status = .open,
        author: String? = nil,
        updatedAt: String? = nil,
        headRef: String? = nil
    ) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.status = status
        self.author = author
        self.updatedAt = updatedAt
        self.headRef = headRef
    }

    /// `owner`/`repo` fall back to the batch's first repository, as the
    /// daemon omits them on single-repository searches.
    init?(wire: [String: Any], owner fallbackOwner: String, repo fallbackRepo: String) {
        guard let number = wire["number"] as? Int, let title = wire["title"] as? String else { return nil }
        let status: WorkspacePrPill.Status
        if wire["merged"] as? Bool == true {
            status = .merged
        } else if (wire["state"] as? String)?.lowercased() == "closed" {
            status = .closed
        } else if wire["draft"] as? Bool == true {
            status = .draft
        } else {
            status = .open
        }
        self.init(
            owner: wire["owner"] as? String ?? fallbackOwner,
            repo: wire["repo"] as? String ?? fallbackRepo,
            number: number,
            title: title,
            url: (wire["htmlUrl"] as? String).flatMap(URL.init(string:)),
            status: status,
            author: (wire["user"] as? [String: Any])?["login"] as? String,
            updatedAt: wire["updatedAt"] as? String,
            headRef: wire["headRef"] as? String
        )
    }

    /// Workspaces keyed by every PR they track (detected pool, active PR),
    /// so a row can open the workspace that owns it. URLs win over the
    /// workspace's own repository because a workspace may track PRs elsewhere.
    static func linkedWorkspaces(_ workspaces: [Workspace]) -> [String: Workspace] {
        var links: [String: Workspace] = [:]
        for workspace in workspaces {
            let pulls = workspace.pullRequests + [workspace.activePullRequest].compactMap { $0 }
            for pull in pulls {
                guard let key = linkKey(pull, workspace: workspace), links[key] == nil else { continue }
                links[key] = workspace
            }
        }
        return links
    }

    /// `/{owner}/{repo}/pull/{number}` path component indices.
    private enum PullPath {
        static let owner = 0
        static let repo = 1
        static let kind = 2
        static let number = 3
    }

    /// A github.com pull request link, titled by its number until details load.
    init?(githubURL url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["github.com", "www.github.com"].contains(url.host()?.lowercased() ?? "") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count > PullPath.number, parts[PullPath.kind] == "pull",
              let number = Int(parts[PullPath.number]) else { return nil }
        let owner = parts[PullPath.owner]
        let repo = parts[PullPath.repo]
        self.init(
            owner: owner,
            repo: repo,
            number: number,
            title: "#\(number)",
            url: URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")
        )
    }

    /// `self` with fields the loaded pull request lacks kept from `other`.
    func filling(from other: Self) -> Self {
        Self(
            owner: owner,
            repo: repo,
            number: number,
            title: title,
            url: url ?? other.url,
            status: status,
            author: author ?? other.author,
            updatedAt: updatedAt ?? other.updatedAt,
            headRef: headRef ?? other.headRef
        )
    }

    /// The pull request a link points at when one of `workspaces` tracks it,
    /// carrying the workspace's title and state for that pull request.
    static func tracked(url: URL, in workspaces: [Workspace]) -> (item: Self, workspace: Workspace)? {
        guard let link = Self(githubURL: url) else { return nil }
        for workspace in workspaces {
            let pulls = workspace.pullRequests + [workspace.activePullRequest].compactMap { $0 }
            guard let pull = pulls.first(where: { linkKey($0, workspace: workspace) == link.id }) else { continue }
            let item = Self(
                owner: link.owner,
                repo: link.repo,
                number: link.number,
                title: pull.title.flatMap { $0.isEmpty ? nil : $0 } ?? link.title,
                url: link.url,
                status: WorkspacePrPill.Status(wire: pull.status),
                updatedAt: pull.updatedAt
            )
            return (item, workspace)
        }
        return nil
    }

    /// The workspace's own pull requests, as the Cloudlands Changes sidebar
    /// lists them: the detected pool (the active PR only when the pool is
    /// empty) in the workspace repository, plus same-repository monitored
    /// PRs, newest-updated first. Needs the workspace repository.
    static func owned(by workspace: Workspace, monitors: [MonitoredPr] = []) -> [Self] {
        guard let owner = workspace.repositoryOwner, let repo = workspace.repositoryName,
              !owner.isEmpty, !repo.isEmpty else { return [] }
        let repoKey = "\(owner)/\(repo)".lowercased()
        let pulls = workspace.pullRequests.isEmpty
            ? [workspace.activePullRequest].compactMap { $0 }
            : workspace.pullRequests
        var items: [Self] = pulls.compactMap { pull in
            let link = pull.url.flatMap(URL.init(string:)).flatMap(Self.init(githubURL:))
            if let link, "\(link.owner)/\(link.repo)".lowercased() != repoKey { return nil }
            return Self(
                owner: owner,
                repo: repo,
                number: pull.number,
                title: pull.title.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(pull.number)",
                url: link?.url ?? URL(string: "https://github.com/\(owner)/\(repo)/pull/\(pull.number)"),
                status: WorkspacePrPill.Status(wire: pull.status),
                updatedAt: pull.updatedAt
            )
        }
        for monitor in monitors where monitor.state != .cancelled && monitor.repo.lowercased() == repoKey {
            guard !items.contains(where: { $0.number == monitor.prNumber }) else { continue }
            items.append(Self(
                owner: owner,
                repo: repo,
                number: monitor.prNumber,
                title: monitor.title.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(monitor.prNumber)",
                url: monitor.url.flatMap(URL.init(string:))
                    ?? URL(string: "https://github.com/\(owner)/\(repo)/pull/\(monitor.prNumber)"),
                status: WorkspacePrPill.monitorDisplayStatus(monitor),
                updatedAt: monitor.updatedAt
            ))
        }
        return items.sorted { lhs, rhs in
            switch (lhs.updatedAt.flatMap { $0.isEmpty ? nil : $0 }, rhs.updatedAt.flatMap { $0.isEmpty ? nil : $0 }) {
            case let (left?, right?) where left != right: left > right
            case (.some, .none): true
            case (.none, .some): false
            default: lhs.number > rhs.number
            }
        }
    }

    private static func linkKey(_ pull: WorkspacePullRequest, workspace: Workspace) -> String? {
        if let link = pull.url.flatMap(URL.init(string:)).flatMap(Self.init(githubURL:)) {
            return link.id
        }
        guard let owner = workspace.repositoryOwner, let repo = workspace.repositoryName,
              !owner.isEmpty, !repo.isEmpty else { return nil }
        return key(owner: owner, repo: repo, number: pull.number)
    }
}

/// Pull requests of one repository, for the grouped list.
struct PullRequestProjectGroup: Identifiable {
    let id: String
    let title: String
    let items: [PullRequestListItem]
}

extension PullRequestListItem {
    /// Groups by repository, keeping the incoming (newest-first) order, so
    /// the most recently updated project leads. Titles name the owner only
    /// when two groups share a repository name.
    static func groupedByProject(_ items: [PullRequestListItem]) -> [PullRequestProjectGroup] {
        var order: [String] = []
        var buckets: [String: [PullRequestListItem]] = [:]
        for item in items {
            let key = "\(item.owner)/\(item.repo)".lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        let names = order.compactMap { buckets[$0]?.first?.repo.lowercased() }
        return order.compactMap { key in
            guard let rows = buckets[key], let first = rows.first else { return nil }
            let ambiguous = names.filter { $0 == first.repo.lowercased() }.count > 1
            return PullRequestProjectGroup(id: key, title: ambiguous ? "\(first.owner)/\(first.repo)" : first.repo, items: rows)
        }
    }
}

/// A GitHub repository the list searches, from the known workspaces.
struct PullRequestListRepository: Hashable {
    let owner: String
    let name: String

    /// Distinct repositories, case-insensitive, sorted for a stable scope key.
    static func scope(_ workspaces: [Workspace]) -> [Self] {
        var seen: Set<String> = []
        return workspaces.compactMap { workspace -> Self? in
            guard let owner = workspace.repositoryOwner, let name = workspace.repositoryName,
                  !owner.isEmpty, !name.isEmpty,
                  seen.insert("\(owner)/\(name)".lowercased()).inserted else { return nil }
            return Self(owner: owner, name: name)
        }
        .sorted { "\($0.owner)/\($0.name)".lowercased() < "\($1.owner)/\($1.name)".lowercased() }
    }
}
