import Foundation

/// One row of the pull requests list: a lenient parse of a
/// `github.pulls.search` result (FE Home `PullWire` parity).
struct PullRequestListItem: Identifiable, Equatable {
    let owner: String
    let repo: String
    let number: Int
    let title: String
    let url: URL?
    let status: WorkspacePrPill.Status
    let author: String?
    let updatedAt: String?

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
        updatedAt: String? = nil
    ) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.status = status
        self.author = author
        self.updatedAt = updatedAt
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
            updatedAt: wire["updatedAt"] as? String
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

    private static func linkKey(_ pull: WorkspacePullRequest, workspace: Workspace) -> String? {
        if let url = pull.url.flatMap(URL.init(string:)), url.host()?.lowercased() == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) {
                return key(owner: parts[0], repo: parts[1], number: number)
            }
        }
        guard let owner = workspace.repositoryOwner, let repo = workspace.repositoryName,
              !owner.isEmpty, !repo.isEmpty else { return nil }
        return key(owner: owner, repo: repo, number: pull.number)
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
