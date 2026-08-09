import Foundation
import Combine

/// GitHub repo data layer for the repo picker (PROTOCOL §5.27).
///
/// Reads via `github.authStatus`, `github.repos.list`, `github.repos.search`
/// and `github.branches.list` over the shared JSON-RPC connection. List reads
/// follow the uniform pagination contract (`limit` + opaque `nextToken`) and
/// accumulate pages up to a hard cap.
@MainActor
class GitHubRepoStore: ObservableObject {
    @Published var isConfigured = false
    @Published var ownRepos: [GitHubRepo] = []
    @Published var searchResults: [GitHubRepo] = []
    @Published var isLoading = false
    @Published var lastError: String?

    /// Page size for paginated reads (§5.27 default 50, max 200).
    static let pageLimit = 100
    /// Hard cap on accumulated items so pagination cannot run away.
    static let maxAccumulated = 500

    private let connectionManager: ConnectionManagerRouting

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
    }

    // MARK: - Auth

    /// `github.authStatus` — the picker only needs `isConfigured`.
    /// Returns the fetched value; errors leave `isConfigured` false.
    @discardableResult
    func fetchAuthStatus() async -> Bool {
        do {
            let result = try await connectionManager.request("github.authStatus")
            let configured = (result as? [String: Any])?["isConfigured"] as? Bool ?? false
            isConfigured = configured
            return configured
        } catch {
            print("[GitHubRepoStore] github.authStatus failed: \(error)")
            isConfigured = false
            return false
        }
    }

    // MARK: - Repos

    /// `github.repos.list` — the authenticated user's repositories,
    /// accumulated across `nextToken` pages up to `maxAccumulated`.
    func fetchOwnRepos() async {
        isLoading = true
        lastError = nil
        do {
            ownRepos = try await fetchAllPages(
                method: "github.repos.list",
                params: [:],
                itemsKey: "repos",
                parse: GitHubRepo.parseRepo
            )
        } catch {
            print("[GitHubRepoStore] github.repos.list failed: \(error)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// `github.repos.search` — one page of global repo search, with the
    /// FE-parity query rewrite (`owner/name` → `name user:owner`). Returns
    /// the parsed results instead of assigning `searchResults`, so the
    /// debounced caller can publish results and the query they answer
    /// together after its own cancellation check (out-of-order responses
    /// would otherwise let an older request overwrite a newer one's
    /// results). Returns nil on error.
    func searchRepos(query: String) async -> [GitHubRepo]? {
        let rewritten = Self.rewriteSearchQuery(query)
        guard !rewritten.isEmpty else { return [] }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let result = try await connectionManager.request("github.repos.search", params: [
                "query": rewritten,
                "limit": Self.pageLimit
            ])
            let items = (result as? [String: Any])?["repos"] as? [[String: Any]] ?? []
            return items.compactMap { GitHubRepo.parseRepo($0) }
        } catch {
            print("[GitHubRepoStore] github.repos.search failed: \(error)")
            lastError = error.localizedDescription
            return nil
        }
    }

    /// `github.repos.get` — resolve a repo's `defaultBranch` when the
    /// list/search DTO omitted it (global-search results often do).
    /// Best-effort: errors and `{ repo: null }` return nil.
    func fetchDefaultBranch(owner: String, repo: String) async -> String? {
        do {
            let result = try await connectionManager.request("github.repos.get", params: [
                "owner": owner,
                "repo": repo
            ])
            let repoDict = (result as? [String: Any])?["repo"] as? [String: Any]
            return repoDict?["defaultBranch"] as? String
        } catch {
            print("[GitHubRepoStore] github.repos.get failed: \(error)")
            return nil
        }
    }

    // MARK: - Branches

    /// `github.branches.list` — remote branch names, accumulated across
    /// `nextToken` pages up to `maxAccumulated`. Throws on transport failure
    /// so callers can distinguish "no branches" from an error.
    func fetchRemoteBranches(owner: String, repo: String) async throws -> [String] {
        try await fetchAllPages(
            method: "github.branches.list",
            params: ["owner": owner, "repo": repo],
            itemsKey: "branches",
            parse: { $0 }
        )
    }

    // MARK: - Query rewrite

    /// Rewrite raw repo-search input into GitHub `/search/repositories`
    /// syntax (parity with the daemon/FE `build_repo_search_query`):
    /// `owner/name` → `name user:owner`, `owner/` → `user:owner`,
    /// `/name` → `name`, bare text → unchanged.
    static func rewriteSearchQuery(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let slash = trimmed.firstIndex(of: "/") else { return trimmed }
        let owner = trimmed[..<slash].trimmingCharacters(in: .whitespaces)
        let name = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        switch (owner.isEmpty, name.isEmpty) {
        case (false, false): return "\(name) user:\(owner)"
        case (false, true): return "user:\(owner)"
        case (true, false): return name
        case (true, true): return ""
        }
    }

    // MARK: - Pagination

    /// Accumulate a paginated `github.*` list read: follows the opaque
    /// `nextToken` cursor until it is absent/null or `maxAccumulated` is hit.
    private func fetchAllPages<Item, Raw>(
        method: String,
        params: [String: Any],
        itemsKey: String,
        parse: (Raw) -> Item?
    ) async throws -> [Item] {
        var accumulated: [Item] = []
        var nextToken: String?
        repeat {
            var pageParams = params
            pageParams["limit"] = Self.pageLimit
            if let token = nextToken {
                pageParams["nextToken"] = token
            }
            let result = try await connectionManager.request(method, params: pageParams)
            let dict = result as? [String: Any] ?? [:]
            let items = dict[itemsKey] as? [Raw] ?? []
            accumulated.append(contentsOf: items.compactMap(parse))
            nextToken = dict["nextToken"] as? String
        } while nextToken != nil && accumulated.count < Self.maxAccumulated
        return accumulated
    }
}
