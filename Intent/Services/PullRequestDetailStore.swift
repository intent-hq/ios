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

    /// Links open with only a number; the loaded pull request fills in its title and state.
    private(set) var item: PullRequestListItem
    private(set) var detail: PullRequestDetail?
    private(set) var checks: [PullRequestCheck] = []
    private(set) var reviewers: [PullRequestReviewer] = []
    private(set) var files: [PullRequestFile] = []
    private(set) var filesTruncated = false
    private(set) var loading: Set<Section> = []
    private(set) var errors: [Section: String] = [:]

    /// A `github.pulls.get` reply without a readable pull request.
    enum ResponseError: LocalizedError, Equatable {
        case malformed

        var errorDescription: String? {
            "Could not read this pull request from the computer running Intent. Try again."
        }
    }

    static let filesLimit = 50
    static let reviewsLimit = 50

    @ObservationIgnored private var requestedReviewers: [String] = []
    @ObservationIgnored private var hasReviewsRequestedReviewers = false
    @ObservationIgnored private var lastReviews: [[String: Any]] = []
    @ObservationIgnored private var sectionGenerations: [Section: Int] = [:]
    private let connection: any ConnectionManagerRouting

    init(item: PullRequestListItem, connection: any ConnectionManagerRouting) {
        self.item = item
        self.connection = connection
    }

    private var address: [String: Any] {
        ["owner": item.owner, "repo": item.repo, "number": item.number]
    }

    func loadAll() async {
        hasReviewsRequestedReviewers = false
        async let detail: Void = load(.detail)
        async let checks: Void = load(.checks)
        async let reviews: Void = load(.reviews)
        async let files: Void = load(.files)
        _ = await (detail, checks, reviews, files)
    }

    func load(_ section: Section) async {
        guard !Task.isCancelled, !loading.contains(section) else { return }
        let generation = (sectionGenerations[section] ?? 0) &+ 1
        sectionGenerations[section] = generation
        loading.insert(section)
        errors[section] = nil
        defer {
            if isCurrent(section, generation: generation) {
                loading.remove(section)
            }
        }
        do {
            try await fetchSection(section, generation: generation)
        } catch is CancellationError {
        } catch {
            guard isCurrent(section, generation: generation), !Task.isCancelled else { return }
            AppLog.github.error("[PullRequestDetailStore] \(String(describing: section)) failed: \(error)")
            errors[section] = error.localizedDescription
        }
    }

    private func isCurrent(_ section: Section, generation: Int) -> Bool {
        sectionGenerations[section] == generation
    }

    private func fetchSection(_ section: Section, generation: Int) async throws {
        switch section {
        case .detail: try await fetchDetail(generation: generation)
        case .checks: try await fetchChecks(generation: generation)
        case .reviews: try await fetchReviews(generation: generation)
        case .files: try await fetchFiles(generation: generation)
        }
    }

    private func fetchDetail(generation: Int) async throws {
        let result = try await connection.request("github.pulls.get", params: address) as? [String: Any]
        guard isCurrent(.detail, generation: generation), !Task.isCancelled else { return }
        guard let pull = result?["pull"] as? [String: Any],
              let loadedDetail = PullRequestDetail(wire: pull) else { throw ResponseError.malformed }
        detail = loadedDetail
        if let loaded = PullRequestListItem(wire: pull, owner: item.owner, repo: item.repo) {
            item = loaded.filling(from: item)
        }
    }

    private func fetchChecks(generation: Int) async throws {
        let result = try await connection.request("github.pulls.checks", params: address) as? [String: Any]
        guard isCurrent(.checks, generation: generation), !Task.isCancelled else { return }
        checks = (result?["checks"] as? [[String: Any]] ?? []).compactMap(PullRequestCheck.init(wire:))
        if !hasReviewsRequestedReviewers, let requested = result?["requestedReviewers"] as? [String] {
            requestedReviewers = requested
        }
        reviewers = PullRequestReviewer.rows(reviews: lastReviews, requested: requestedReviewers)
    }

    private func fetchReviews(generation: Int) async throws {
        var params = address
        params["limit"] = Self.reviewsLimit
        let result = try await connection.request("github.pulls.reviews", params: params) as? [String: Any]
        guard isCurrent(.reviews, generation: generation), !Task.isCancelled else { return }
        lastReviews = result?["reviews"] as? [[String: Any]] ?? []
        if let requested = result?["requestedReviewers"] as? [String] {
            requestedReviewers = requested
            hasReviewsRequestedReviewers = true
        }
        reviewers = PullRequestReviewer.rows(reviews: lastReviews, requested: requestedReviewers)
    }

    private func fetchFiles(generation: Int) async throws {
        var params = address
        params["limit"] = Self.filesLimit
        let result = try await connection.request("github.pulls.files", params: params) as? [String: Any]
        guard isCurrent(.files, generation: generation), !Task.isCancelled else { return }
        files = (result?["files"] as? [[String: Any]] ?? []).compactMap(PullRequestFile.init(wire:))
        filesTruncated = result?["truncated"] as? Bool == true || result?["nextToken"] is String
    }

    func reset() {
        for section in [Section.checks, .detail, .files, .reviews] {
            sectionGenerations[section] = (sectionGenerations[section] ?? 0) &+ 1
        }
        loading.removeAll()
        errors.removeAll()
        detail = nil
        checks = []
        reviewers = []
        files = []
        filesTruncated = false
        requestedReviewers = []
        hasReviewsRequestedReviewers = false
        lastReviews = []
    }
}
