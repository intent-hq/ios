import Foundation

/// Wire `GithubRepo` DTO (PROTOCOL §5.27) — camelCase on the wire.
/// Only `owner` + `name` are required; everything else is optional and
/// parsing tolerates its absence.
struct GitHubRepo: Identifiable, Equatable {
    let owner: String
    let name: String
    let htmlUrl: String?
    let defaultBranch: String?
    let updatedAt: String?

    /// Stable identity — GitHub repos are unique per `owner/name`.
    var id: String { fullName }

    /// The canonical `owner/name` display form.
    var fullName: String { "\(owner)/\(name)" }

    static func parseRepo(_ dict: [String: Any]) -> GitHubRepo? {
        guard let owner = dict["owner"] as? String,
              let name = dict["name"] as? String,
              !owner.isEmpty, !name.isEmpty else { return nil }
        return GitHubRepo(
            owner: owner,
            name: name,
            htmlUrl: dict["htmlUrl"] as? String,
            defaultBranch: dict["defaultBranch"] as? String,
            updatedAt: dict["updatedAt"] as? String
        )
    }
}

/// One repo's branch names plus its default branch, as the branch picker
/// renders them. Produced both by the authoritative `github.branches.list`
/// read and by the cached-first `github.branches.listCached` paint
/// (PROTOCOL §5.27); `defaultBranch` is nil when unresolvable.
struct GitHubBranchListing: Equatable {
    let branches: [String]
    let defaultBranch: String?
}

/// The branch step's state for one repo, owned by `GitHubRepoStore` so every
/// consumer (two sheets on one session, a retry, a reconnect) renders one
/// outcome: the authoritative listing, the cached-first paint shown only
/// until it lands, and the last cold-load error (cleared by a success).
struct GitHubBranchLoadState: Equatable {
    var listing: GitHubBranchListing? = nil
    var paint: GitHubBranchListing? = nil
    var error: String? = nil

    /// What the branch step renders: authoritative first, else the paint.
    var displayed: GitHubBranchListing? { listing ?? paint }
}
