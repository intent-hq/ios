import Foundation
import Observation

/// Pull requests across the repositories of the known workspaces — the
/// mobile counterpart of the FE Home pull requests list.
///
/// Reads `github.authStatus`, then `github.pulls.search` in batches of
/// `batchSize` repositories (FE `repositories()` parity). Each batch keeps its
/// own `nextToken`, so "load more" only re-asks batches with more results.
@MainActor
@Observable final class PullRequestListStore {
    nonisolated enum Filter: String, CaseIterable {
        case all = "All"
        case created = "Created"
        case reviewRequested = "Review"
        case assigned = "Assigned"

        var wireValue: String {
            switch self {
            case .all: "all"
            case .created: "created"
            case .reviewRequested: "review-requested"
            case .assigned: "assigned"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case disconnected
        case failed(String)
    }

    struct Query: Equatable {
        var repositories: [PullRequestListRepository] = []
        var filter: Filter = .all
        var showsClosed = false
        var text = ""
    }

    static let batchSize = 6
    static let pageLimit = 30

    private(set) var items: [PullRequestListItem] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    private(set) var loadedQuery: Query?
    var hasMore: Bool { cursors.contains { $0 != nil } }

    @ObservationIgnored private var cursors: [String?] = []
    @ObservationIgnored private var generation = 0
    private let connection: any ConnectionManagerRouting

    init(connection: any ConnectionManagerRouting) {
        self.connection = connection
    }

    /// Replaces the list for `query`. A newer call supersedes an older one;
    /// rows from the previous query stay visible until the new page lands.
    func load(_ query: Query) async {
        generation &+= 1
        let current = generation
        phase = .loading
        isLoadingMore = false
        guard !query.repositories.isEmpty else {
            finish(query, items: [], cursors: [], generation: current)
            return
        }
        do {
            let auth = try await connection.request("github.authStatus")
            guard current == generation else { return }
            guard (auth as? [String: Any])?["isConfigured"] as? Bool == true else {
                items = []
                cursors = []
                loadedQuery = query
                phase = .disconnected
                return
            }
            let batches = Self.batches(query.repositories)
            let pages = try await fetch(query, batches: batches, cursors: Array(repeating: nil, count: batches.count))
            guard current == generation else { return }
            finish(query, items: pages.items, cursors: pages.cursors, generation: current)
        } catch {
            guard current == generation else { return }
            AppLog.github.error("[PullRequestListStore] load failed: \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard let query = loadedQuery, hasMore, !isLoadingMore, phase == .ready else { return }
        let current = generation
        isLoadingMore = true
        defer { if current == generation { isLoadingMore = false } }
        do {
            let pages = try await fetch(query, batches: Self.batches(query.repositories), cursors: cursors, more: true)
            guard current == generation else { return }
            let known = Set(items.map(\.id))
            items += pages.items.filter { !known.contains($0.id) }
            cursors = pages.cursors
        } catch {
            AppLog.github.error("[PullRequestListStore] loadMore failed: \(error)")
        }
    }

    func reset() {
        generation &+= 1
        items = []
        cursors = []
        loadedQuery = nil
        isLoadingMore = false
        phase = .idle
    }

    static func batches(_ repositories: [PullRequestListRepository]) -> [[PullRequestListRepository]] {
        stride(from: 0, to: repositories.count, by: batchSize).map {
            Array(repositories[$0..<min($0 + batchSize, repositories.count)])
        }
    }

    private func finish(_ query: Query, items: [PullRequestListItem], cursors: [String?], generation current: Int) {
        guard current == generation else { return }
        self.items = items
        self.cursors = cursors
        loadedQuery = query
        phase = .ready
    }

    /// One request per batch; with `more`, batches without a cursor are
    /// skipped. Rows are newest-updated first across batches.
    private func fetch(
        _ query: Query,
        batches: [[PullRequestListRepository]],
        cursors: [String?],
        more: Bool = false
    ) async throws -> (items: [PullRequestListItem], cursors: [String?]) {
        var items: [PullRequestListItem] = []
        var nextCursors: [String?] = []
        for (index, batch) in batches.enumerated() {
            let cursor = index < cursors.count ? cursors[index] : nil
            guard let first = batch.first, !more || cursor != nil else {
                nextCursors.append(nil)
                continue
            }
            var params: [String: Any] = [
                "owner": first.owner,
                "repo": first.name,
                "repos": batch.dropFirst().map { ["owner": $0.owner, "repo": $0.name] },
                "limit": Self.pageLimit,
                "filter": query.filter.wireValue,
                "state": query.showsClosed ? "closed" : "open"
            ]
            let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { params["query"] = text }
            if more, let cursor { params["nextToken"] = cursor }
            let result = try await connection.request("github.pulls.search", params: params)
            let response = result as? [String: Any]
            let pulls = response?["pulls"] as? [[String: Any]] ?? []
            items += pulls.compactMap { PullRequestListItem(wire: $0, owner: first.owner, repo: first.name) }
            nextCursors.append(response?["nextToken"] as? String)
        }
        let sorted = items.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        return (sorted, nextCursors)
    }
}
