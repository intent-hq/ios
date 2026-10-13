import Combine
import Foundation
import Observation

enum GitHubRepoSearchOutcome {
    case failed
    case results([GitHubRepo])
}

/// GitHub repo data layer for the repo picker (PROTOCOL §5.27).
///
/// Reads via `repo.list`, `github.authStatus`, `github.repos.list`,
/// `github.repos.search`, `github.branches.list` and
/// `github.branches.listCached` over the shared JSON-RPC connection. All
/// reads are single-page so the pickers render after one round-trip;
/// server-side search covers anything beyond the first page.
///
/// Session-lifetime cache (owned by `BackendSession`): the first
/// `loadIfNeeded()` blocks with `isLoading`; later calls return immediately
/// with the cached lists and revalidate silently in the background
/// (stale-while-revalidate, FE github-repos slice parity). Branch listings
/// are cached per repo under the same contract (`branchStates`). A
/// reconnect hard-clears the cache and reloads cold: stale lists never
/// survive a connection flap.
@MainActor
@Observable class GitHubRepoStore {
    var isConfigured = false
    var recentRepos: [GitHubRepo] = []
    var ownRepos: [GitHubRepo] = []
    /// Branch-step state keyed by `owner/repo`: the authoritative listing
    /// (filled only by `loadBranchListing`, so a repo the picker has already
    /// visited renders synchronously on the next visit), the cached-first
    /// paint and the cold-load error. Store-owned so no sheet keeps a local
    /// snapshot that a reconnect clear or another sheet's load cannot reach.
    private(set) var branchStates: [String: GitHubBranchLoadState] = [:]
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
    /// Bumped by `invalidate()`: a load captures it on start and every
    /// write after an await is dropped once it no longer matches, so a
    /// completion from before an invalidation cannot repopulate the cache.
    /// Observable so an open branch step can reload — and re-warm — its
    /// repo after the reconnect clear even when it held no listing yet.
    private(set) var loadGeneration = 0
    /// True from the first `loadIfNeeded()` or `loadBranchListing` until
    /// `invalidate()`, whether that load is in flight, succeeded or failed —
    /// a reconnect hard-clears and re-warms only a cache the picker has
    /// asked for.
    @ObservationIgnored private var hasAttemptedLoad = false
    /// Single-flight per repo: a branch load already in flight is joined.
    @ObservationIgnored private var branchLoadTasks: [String: Task<GitHubBranchListing, Error>] = [:]
    /// Repos already warmed this session (FE `RepoCacheWarmer` parity: each
    /// repo fires `repo.warmCache` at most once per warmer lifetime).
    @ObservationIgnored private var warmedRepos: Set<String> = []
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
    /// `loadIfNeeded()` runs as a cold load. A load in flight is superseded:
    /// its completion is dropped (see `loadGeneration`) and it is no longer
    /// joined, so the next call starts a fresh flight. Branch state (listing,
    /// paint, error), in-flight branch loads and the warmed-repo set are
    /// dropped the same way.
    func invalidate() {
        loadGeneration &+= 1
        loadTask = nil
        branchLoadTasks = [:]
        warmedRepos = []
        hasAttemptedLoad = false
        isLoading = false
        recentRepos = []
        ownRepos = []
        branchStates = [:]
        isConfigured = false
        lastError = nil
        hasCheckedAuth = false
        hasLoaded = false
        lastLoadedAt = nil
    }

    /// Single-flight: a load already in flight is joined, not duplicated.
    private func startLoad(silent: Bool) {
        hasAttemptedLoad = true
        guard loadTask == nil else { return }
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.runLoad(silent: silent, generation: generation)
            guard let self, loadGeneration == generation else { return }
            loadTask = nil
        }
    }

    private func runLoad(silent: Bool, generation: Int) async {
        // The task may first run after an invalidate() that superseded it:
        // touch nothing (an `isLoading` set here would never be cleared).
        guard generation == loadGeneration else { return }
        if !silent { isLoading = true }
        lastError = nil
        // Recents come from the daemon registry (no GitHub round-trip), so
        // fetch them concurrently with the auth-gated GitHub list.
        async let recents: Void = fetchRecentRepos(generation: generation)
        let configured = await fetchAuthStatus(generation: generation)
        guard generation == loadGeneration else { return }
        // A transport error on the auth read fails the load: cached auth and
        // lists stay as they were, and a cold load is retried next time.
        var succeeded = configured != nil
        if configured != nil { hasCheckedAuth = true }
        if configured == true {
            succeeded = await fetchOwnRepos(generation: generation)
        }
        await recents
        guard generation == loadGeneration else { return }
        if succeeded {
            hasLoaded = true
            lastLoadedAt = Date()
        }
        if !silent { isLoading = false }
    }

    /// A reconnect hard-clears the cache (the daemon may have changed
    /// underneath it) and reloads cold, so stale lists never stay visible
    /// across a connection flap and a pre-reconnect load is neither joined
    /// nor applied. A failed load counts too (its recents and error are
    /// stale as well). With no load ever requested there is nothing to
    /// re-warm until the picker asks.
    private func onConnected() async {
        guard hasAttemptedLoad else { return }
        invalidate()
        await loadIfNeeded()
    }

    // MARK: - Auth

    /// `github.authStatus` — the picker only needs `isConfigured`.
    /// Returns the fetched value, or nil on transport error — which leaves
    /// `isConfigured` untouched so a failed background refresh cannot turn a
    /// cached, connected picker into not-connected guidance.
    @discardableResult
    // nil is a transport failure; false is a successful unconfigured result.
    // swiftlint:disable:next discouraged_optional_boolean
    func fetchAuthStatus() async -> Bool? {
        await fetchAuthStatus(generation: loadGeneration)
    }

    // Nil means a failed or superseded read; false is an authoritative unconfigured result.
    // swiftlint:disable:next discouraged_optional_boolean
    private func fetchAuthStatus(generation: Int) async -> Bool? {
        do {
            let result = try await connectionManager.request("github.authStatus")
            guard generation == loadGeneration else { return nil }
            let configured = (result as? [String: Any])?["isConfigured"] as? Bool ?? false
            isConfigured = configured
            return configured
        } catch {
            AppLog.github.error("[GitHubRepoStore] github.authStatus failed: \(error)")
            guard generation == loadGeneration else { return nil }
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
        await fetchRecentRepos(generation: loadGeneration)
    }

    private func fetchRecentRepos(generation: Int) async {
        do {
            let result = try await connectionManager.request("repo.list")
            guard generation == loadGeneration,
                  let items = (result as? [String: Any])?["repos"] as? [[String: Any]] else { return }
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
        await fetchOwnRepos(generation: loadGeneration)
    }

    private func fetchOwnRepos(generation: Int) async -> Bool {
        lastError = nil
        do {
            let result = try await connectionManager.request("github.repos.list", params: [
                "limit": Self.ownReposLimit
            ])
            guard generation == loadGeneration else { return false }
            let items = (result as? [String: Any])?["repos"] as? [[String: Any]] ?? []
            ownRepos = items.compactMap { GitHubRepo.parseRepo($0) }
            return true
        } catch {
            AppLog.github.error("[GitHubRepoStore] github.repos.list failed: \(error)")
            guard generation == loadGeneration else { return false }
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
    func searchRepos(query: String) async -> GitHubRepoSearchOutcome {
        let rewritten = Self.rewriteSearchQuery(query)
        guard !rewritten.isEmpty else { return .results([]) }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let result = try await connectionManager.request("github.repos.search", params: [
                "query": rewritten,
                "limit": Self.pageLimit
            ])
            let items = (result as? [String: Any])?["repos"] as? [[String: Any]] ?? []
            return .results(items.compactMap { GitHubRepo.parseRepo($0) })
        } catch {
            AppLog.github.error("[GitHubRepoStore] github.repos.search failed: \(error)")
            lastError = error.localizedDescription
            return .failed
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

    /// The branch step's state for `owner/repo`; empty (loading) until a
    /// load has been asked for.
    func branchState(owner: String, repo: String) -> GitHubBranchLoadState {
        branchStates[Self.branchKey(owner: owner, repo: repo)] ?? GitHubBranchLoadState()
    }

    /// The authoritative listing cached for `owner/repo`, if this session
    /// has loaded one; nil means the branch step must load.
    func cachedBranchListing(owner: String, repo: String) -> GitHubBranchListing? {
        branchStates[Self.branchKey(owner: owner, repo: repo)]?.listing
    }

    /// Loads the authoritative listing for one repo — the repo's default
    /// branch (`defaultBranch` when the picker already knows it, else
    /// `github.repos.get`) plus the first page of `github.branches.list` —
    /// and publishes it in `branchStates`. Single-flight per repo; a
    /// completion from before an `invalidate()` is returned but not
    /// published. Cold (no listing yet): clears the error, paints the
    /// daemon's local cache (`github.branches.listCached`) as soon as it
    /// answers, and on failure publishes the error for every consumer. A
    /// failed refresh keeps the cached listing and stays silent. Throws so a
    /// direct caller can react too.
    @discardableResult
    func loadBranchListing(
        owner: String, repo: String, defaultBranch: String? = nil
    ) async throws -> GitHubBranchListing {
        let key = Self.branchKey(owner: owner, repo: repo)
        hasAttemptedLoad = true
        if let inFlight = branchLoadTasks[key] {
            return try await inFlight.value
        }
        let generation = loadGeneration
        if branchStates[key]?.listing == nil {
            branchStates[key] = GitHubBranchLoadState(paint: branchStates[key]?.paint)
            paintCachedBranches(owner: owner, repo: repo, key: key, generation: generation)
        }
        let task = Task<GitHubBranchListing, Error> { [self] in
            var resolvedDefault = defaultBranch
            if resolvedDefault == nil {
                resolvedDefault = await fetchDefaultBranch(owner: owner, repo: repo)
            }
            let branches = try await fetchRemoteBranches(owner: owner, repo: repo)
            return GitHubBranchListing(branches: branches, defaultBranch: resolvedDefault)
        }
        branchLoadTasks[key] = task
        defer {
            if generation == loadGeneration, branchLoadTasks[key] == task {
                branchLoadTasks[key] = nil
            }
        }
        do {
            let listing = try await task.value
            if generation == loadGeneration {
                branchStates[key] = GitHubBranchLoadState(listing: listing)
            }
            return listing
        } catch {
            if generation == loadGeneration, branchStates[key]?.listing == nil {
                branchStates[key] = GitHubBranchLoadState(error: error.localizedDescription)
            }
            throw error
        }
    }

    /// The cached-first paint for a cold load: published only while the
    /// same generation is still waiting on the authoritative read (no
    /// listing, no error yet), so a late answer from before a reconnect or
    /// after the authoritative outcome cannot land.
    private func paintCachedBranches(owner: String, repo: String, key: String, generation: Int) {
        Task { [self] in
            guard let paint = await fetchCachedBranches(owner: owner, repo: repo),
                  generation == loadGeneration,
                  let state = branchStates[key], state.listing == nil, state.error == nil
            else { return }
            branchStates[key]?.paint = paint
        }
    }

    /// `github.branches.listCached` — the daemon's local repo cache (or its
    /// one-shot `ls-remote` fallback), for a first paint before the
    /// authoritative read lands. Never an error authority: a transport
    /// failure, a `-32601` from an older daemon, or an empty listing all
    /// read as a cache miss (nil). Never promoted to `listing`.
    func fetchCachedBranches(owner: String, repo: String) async -> GitHubBranchListing? {
        do {
            let result = try await connectionManager.request("github.branches.listCached", params: [
                "owner": owner,
                "repo": repo
            ])
            guard let branches = (result as? [String: Any])?["branches"] as? [String],
                  !branches.isEmpty else { return nil }
            let defaultBranch = (result as? [String: Any])?["defaultBranch"] as? String
            return GitHubBranchListing(
                branches: branches,
                defaultBranch: defaultBranch.flatMap { $0.isEmpty ? nil : $0 }
            )
        } catch {
            AppLog.github.info("[GitHubRepoStore] github.branches.listCached miss: \(error)")
            return nil
        }
    }

    /// `repo.warmCache` — fire-and-forget refresh of the daemon's repo cache
    /// so the later `workspace.create` hydrates from a fresh cache (PROTOCOL
    /// §5.11). Best-effort: every failure (warm already in flight, `-32601`
    /// on an older daemon, offline) is logged only. At most one request per
    /// repo per session.
    func warmRepoCache(owner: String, repo: String) {
        guard warmedRepos.insert(Self.branchKey(owner: owner, repo: repo)).inserted else { return }
        Task { [self] in
            do {
                _ = try await connectionManager.request("repo.warmCache", params: [
                    "githubUrl": "https://github.com/\(owner)/\(repo)"
                ])
            } catch {
                AppLog.github.info("[GitHubRepoStore] repo.warmCache failed (ignored): \(error)")
            }
        }
    }

    private static func branchKey(owner: String, repo: String) -> String {
        "\(owner)/\(repo)"
    }

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
