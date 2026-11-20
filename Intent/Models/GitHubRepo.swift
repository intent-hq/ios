import Foundation

struct GitHubRepo: Identifiable, Equatable {
    let owner: String
    let name: String
    let htmlUrl: String?
    let defaultBranch: String?
    let updatedAt: String?

    var id: String { fullName }

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

struct GitHubBranchListing: Equatable {
    let branches: [String]
    let defaultBranch: String?
}

struct GitHubBranchLoadState: Equatable {
    var listing: GitHubBranchListing?
    var paint: GitHubBranchListing?
    var error: String?

    var displayed: GitHubBranchListing? { listing ?? paint }
}
