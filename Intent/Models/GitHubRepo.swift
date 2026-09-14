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

    static func parseRepo(_ dict: [String: Any]) -> Self? {
        guard let owner = dict["owner"] as? String,
              let name = dict["name"] as? String,
              !owner.isEmpty, !name.isEmpty else { return nil }
        return Self(
            owner: owner,
            name: name,
            htmlUrl: dict["htmlUrl"] as? String,
            defaultBranch: dict["defaultBranch"] as? String,
            updatedAt: dict["updatedAt"] as? String
        )
    }
}
