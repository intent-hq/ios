import Foundation
import Observation

/// Loads one pull request's detail, checks, reviews and changed files (FE
/// Home detail parity). Each read is independent: one failing leaves the
/// others visible with their own retry.
@MainActor
@Observable final class PullRequestDetailStore {
    enum Section: Hashable {
        case checks, detail, files, reviews
    }

    let item: PullRequestListItem
    private(set) var detail: PullRequestDetail?
    private(set) var checks: [PullRequestCheck] = []
    private(set) var reviewers: [PullRequestReviewer] = []
    private(set) var files: [PullRequestFile] = []
    private(set) var filesTruncated = false
    private(set) var loading: Set<Section> = []
    private(set) var errors: [Section: String] = [:]

    static let filesLimit = 50
    static let reviewsLimit = 50

    @ObservationIgnored private var requestedReviewers: [String] = []
    private let connection: any ConnectionManagerRouting

    init(item: PullRequestListItem, connection: any ConnectionManagerRouting) {
        self.item = item
        self.connection = connection
    }

    private var address: [String: Any] {
        ["owner": item.owner, "repo": item.repo, "number": item.number]
    }

    func loadAll() async {
        async let detail: Void = load(.detail)
        async let checks: Void = load(.checks)
        async let reviews: Void = load(.reviews)
        async let files: Void = load(.files)
        _ = await (detail, checks, reviews, files)
    }

    func load(_ section: Section) async {
        guard !loading.contains(section) else { return }
        loading.insert(section)
        errors[section] = nil
        defer { loading.remove(section) }
        do {
            switch section {
            case .detail:
                let result = try await connection.request("github.pulls.get", params: address) as? [String: Any]
                detail = (result?["pull"] as? [String: Any]).flatMap(PullRequestDetail.init(wire:)) ?? PullRequestDetail()
            case .checks:
                let result = try await connection.request("github.pulls.checks", params: address) as? [String: Any]
                checks = (result?["checks"] as? [[String: Any]] ?? []).compactMap(PullRequestCheck.init(wire:))
                requestedReviewers = result?["requestedReviewers"] as? [String] ?? requestedReviewers
                reviewers = PullRequestReviewer.rows(reviews: lastReviews, requested: requestedReviewers)
            case .reviews:
                var params = address
                params["limit"] = Self.reviewsLimit
                let result = try await connection.request("github.pulls.reviews", params: params) as? [String: Any]
                lastReviews = result?["reviews"] as? [[String: Any]] ?? []
                requestedReviewers = result?["requestedReviewers"] as? [String] ?? requestedReviewers
                reviewers = PullRequestReviewer.rows(reviews: lastReviews, requested: requestedReviewers)
            case .files:
                var params = address
                params["limit"] = Self.filesLimit
                let result = try await connection.request("github.pulls.files", params: params) as? [String: Any]
                files = (result?["files"] as? [[String: Any]] ?? []).compactMap(PullRequestFile.init(wire:))
                filesTruncated = result?["truncated"] as? Bool == true || result?["nextToken"] is String
            }
        } catch {
            AppLog.github.error("[PullRequestDetailStore] \(String(describing: section)) failed: \(error)")
            errors[section] = error.localizedDescription
        }
    }

    @ObservationIgnored private var lastReviews: [[String: Any]] = []
}
