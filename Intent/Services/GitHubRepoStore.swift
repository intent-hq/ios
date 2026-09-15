import Combine
import Foundation
import Observation

/// GitHub repo data layer for the repo picker (PROTOCOL §5.27).
///
/// Reads via `repo.list`, `github.authStatus`, `github.repos.list`,
/// `github.repos.search` and `github.branches.list` over the shared JSON-RPC
/// connection. All reads are single-page so the pickers render after one
/// round-trip; server-side search covers anything beyond the first page.
///
/// Session-lifetime cache (owned by `BackendSession`): the first
/// `loadIfNeeded()` blocks with `isLoading`; later calls return immediately
/// with the cached lists and revalidate silently in the background
/// (stale-while-revalidate, FE github-repos slice parity). A reconnect
/// refreshes an existing cache the same silent way.
@MainActor
@Observable class GitHubRepoStore {
    var isConfigured = false
    var recentRepos: [GitHubRepo] = []
    var ownRepos: [GitHubRepo] = []
    /// True only while a cold (uncached) load is in flight, or during a
    /// search; background revalidation never sets it.
    var isLoading = false
    var lastError: String?
    /// True once a `github.authStatus` read succeeded, so the picker doesn't
    /// flash not-connected guidance while auth is unknown; a transport error
    /// never sets it (nor clears a cached value).
    private(set) var hasCheckedAuth = false
    /// True once a load completed without a transport error; a failed load
    /// leaves it false so the next `loadIfNeeded()` retries as a cold load
    /// (FE parity: an errored load is retried explicitly, not skipped).
    private(set) var hasLoaded = false
    private(set) var lastLoadedAt: Date?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var connectionObserver: AnyCancellable?

    /// Page size for `github.repos.search` (§5.27 default 50, max 200).
    static let pageLimit = 100
    /// Single-page cap for `github.repos.list` — the picker shows recents
    /// first, so only the first page of GitHub repos is blended in below.
    static let ownReposLimit = 50
    /// Single-page cap for `github.branches.list` — the branch picker pins
    /// the default branch on top and prefix search covers the rest.
    static let branchesLimit = 50

    private let connectionManager: ConnectionManagerRouting

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        connectionObserver = connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
    }

    // MARK: - Cache

    /// Loads auth status, recents and the first page of own repos.
    ///
    /// - Cold (nothing cached): awaits the load with `isLoading` set; a
    ///   concurrent call joins the in-flight load.
    /// - Cached and `force == false`: returns immediately and revalidates in
    ///   the background without touching `isLoading` or the cached lists
    ///   (a failed refresh keeps the stale lists).
    /// - `force == true`: refetches; awaited, silent when a cache exists.
    func loadIfNeeded(force: Bool = false) async {
        guard force || !hasLoaded else {
            startLoad(silent: true)
            return
        }
        startLoad(silent: hasLoaded)
        await loadTask?.value
    }

    /// Drops every cached list and the auth/loaded markers so the next
    /// `loadIfNeeded()` runs as a cold load.
    func invalidate() {
        recentRepos = []
        ownRepos = []
        isConfigured = false
        lastError = nil
        hasCheckedAuth = false
        hasLoaded = false
        lastLoadedAt = nil
    }

    /// Single-flight: a load already in flight is joined, not duplicated.
    private func startLoad(silent: Bool) {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            await self?.runLoad(silent: silent)
            self?.loadTask = nil
        }
    }

    private func runLoad(silent: Bool) async {
        if !silent { isLoading = true }
        lastError = nil
        // Recents come from the daemon registry (no GitHub round-trip), so
        // fetch them concurrently with the auth-gated GitHub list.
        async let recents: Void = fetchRecentRepos()
        let configured = await fetchAuthStatus()
        // A transport error on the auth read fails the load: cached auth and
        // lists stay as they were, and a cold load is retried next time.
        var succeeded = configured != nil
        if configured != nil { hasCheckedAuth = true }
        if configured == true {
            succeeded = await fetchOwnRepos()
        }
        await recents
        if succeeded {
            hasLoaded = true
            lastLoadedAt = Date()
        }
        if !silent { isLoading = false }
    }

    /// A reconnect refreshes an existing cache in place; with nothing cached
    /// there is nothing to re-warm until the picker asks.
    private func onConnected() async {
        guard hasLoaded else { return }
        await loadIfNeeded(force: true)
    }

    // MARK: - Auth

    /// `github.authStatus` — the picker only needs `isConfigured`.
    /// Returns the fetched value, or nil on transport error — which leaves
    /// `isConfigured` untouched so a failed background refresh cannot turn a
    /// cached, connected picker into not-connected guidance.
    @discardableResult
    func fetchAuthStatus() async -> Bool? {
        do {
            let result = try await connectionManager.request("github.authStatus")
            let configured = (result as? [String: Any])?["isConfigured"] as? Bool ?? false
            isConfigured = configured
            return configured
        } catch {
            AppLog.github.error("[GitHubRepoStore] github.authStatus failed: \(error)")
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Repos

    /// `repo.list` — the daemon's known-repo registry, MRU-first (PROTOCOL
    /// §5.11). Entries without an `owner` are skipped (they cannot be
    /// addressed as GitHub repos); the daemon's MRU order is preserved.
    /// No GitHub round-trip, so recents render before `github.repos.list`
    /// answers. Best-effort: errors and malformed responses leave
    /// `recentRepos` unchanged.
    func fetchRecentRepos() async {
        do {
            let result = try await connectionManager.request("repo.list")
            guard let items = (result as? [String: Any])?["repos"] as? [[String: Any]] else { return }
            recentRepos = items.compactMap { GitHubRepo.parseRepo($0) }
        } catch {
            AppLog.github.error("[GitHubRepoStore] repo.list failed: \(error)")
        }
    }

    /// `github.repos.list` — a single page (`ownReposLimit`) of the
    /// authenticated user's repositories. Deliberately not paginated: the
    /// picker pins recents on top and server-side search covers the rest.
    /// Returns false on transport error, leaving `ownRepos` unchanged so a
    /// background refresh keeps the cached page. `isLoading` is driven by
    /// `loadIfNeeded`, not here.
    @discardableResult
    func fetchOwnRepos() async -> Bool {
        lastError = nil
        do {
            let result = try await connectionManager.request("github.repos.list", params: [
                "limit": Self.ownReposLimit
            ])
            let items = (result as? [String: Any])?["repos"] as? [[String: Any]] ?? []
            ownRepos = items.compactMap { GitHubRepo.parseRepo($0) }
            return true
        } catch {
            AppLog.github.error("[GitHubRepoStore] github.repos.list failed: \(error)")
            lastError = error.localizedDescription
            return false
        }
    }

    /// `github.repos.search` — one page of global repo search, with the
    /// FE-parity query rewrite (`owner/name` → `name user:owner`). Returns
    /// the parsed results rather than storing them: search results are
    /// per-picker view state (this store is shared session-wide), and the
    /// debounced caller publishes results and the query they answer
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
            AppLog.github.error("[GitHubRepoStore] github.repos.search failed: \(error)")
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
            AppLog.github.error("[GitHubRepoStore] github.repos.get failed: \(error)")
            return nil
        }
    }

    // MARK: - Branches

    /// `github.branches.list` — a single page (`branchesLimit`) of remote
    /// branch names, optionally narrowed server-side by `prefix` (omitted
    /// when nil/blank). Deliberately not paginated: the branch picker pins
    /// the default branch on top and prefix search covers the rest. Throws
    /// on transport failure so callers can distinguish "no branches" from
    /// an error.
    func fetchRemoteBranches(owner: String, repo: String, prefix: String? = nil) async throws -> [String] {
        var params: [String: Any] = [
            "owner": owner,
            "repo": repo,
            "limit": Self.branchesLimit
        ]
        if let prefix, !prefix.isEmpty {
            params["prefix"] = prefix
        }
        let result = try await connectionManager.request("github.branches.list", params: params)
        return (result as? [String: Any])?["branches"] as? [String] ?? []
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
}
