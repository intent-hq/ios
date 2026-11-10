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
    enum AuthState: Equatable {
        case configured
        case unconfigured
        case unknown
    }

    enum CacheState: Equatable {
        case cold
        case failedCold
        case loaded(Date)
        case loadingCold
    }

    private(set) var authState: AuthState = .unknown
    private(set) var cacheState: CacheState = .cold
    private var activeSearchCount = 0

    var isConfigured: Bool {
        get { authState == .configured }
        set { authState = newValue ? .configured : (hasCheckedAuth ? .unconfigured : .unknown) }
    }
    var recentRepos: [GitHubRepo] = []
    var ownRepos: [GitHubRepo] = []
    /// Branch-step state keyed by `owner/repo`: the authoritative listing
    /// (filled only by `loadBranchListing`, so a repo the picker has already
    /// visited renders synchronously on the next visit), the cached-first
    /// paint and the cold-load error. Store-owned so no sheet keeps a local
    /// snapshot that a reconnect clear or another sheet's load cannot reach.
    var branchStates: [String: GitHubBranchLoadState] = [:]
    /// True while a cold (uncached) load is in flight, or during a search;
    /// background revalidation never sets it, and finishing a search never
    /// clears a concurrent cold load.
    var isLoading: Bool { cacheState == .loadingCold || activeSearchCount > 0 }
    var lastError: String?
    /// True once a `github.authStatus` read succeeded, so the picker doesn't
    /// flash not-connected guidance while auth is unknown; a transport error
    /// never sets it (nor clears a cached value).
    var hasCheckedAuth: Bool { authState != .unknown }
    /// True once a load completed without a transport error; a failed load
    /// leaves it false so the next `loadIfNeeded()` retries as a cold load
    /// (FE parity: an errored load is retried explicitly, not skipped).
    var hasLoaded: Bool {
        if case .loaded = cacheState { return true }
        return false
    }
    var lastLoadedAt: Date? {
        if case let .loaded(date) = cacheState { return date }
        return nil
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Test-visible completion handles, kept after `invalidate()` so a test
    /// can await superseded work's real completion. Never read by the store.
    @ObservationIgnored private(set) var latestLoadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var latestConnectionTask: Task<Void, Never>?
    @ObservationIgnored var latestBranchPaintTask: Task<Void, Never>?
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
    private var hasAttemptedLoad: Bool {
        cacheState != .cold || !branchStates.isEmpty || !branchLoadTasks.isEmpty
    }
    /// Single-flight per repo: a branch load already in flight is joined.
    @ObservationIgnored var branchLoadTasks: [String: Task<GitHubBranchListing, Error>] = [:]
    /// Repos already warmed this session (FE `RepoCacheWarmer` parity: each
    /// repo fires `repo.warmCache` at most once per warmer lifetime).
    @ObservationIgnored var warmedRepos: Set<String> = []
    @ObservationIgnored private var connectionObserver: AnyCancellable?

    /// Page size for `github.repos.search` (§5.27 default 50, max 200).
    static let pageLimit = 100
    /// Single-page cap for `github.repos.list` — the picker shows recents
    /// first, so only the first page of GitHub repos is blended in below.
    static let ownReposLimit = 50
    /// Single-page cap for `github.branches.list` — the branch picker pins
    /// the default branch on top and prefix search covers the rest.
    static let branchesLimit = 50

    let connectionManager: ConnectionManagerRouting

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        connectionObserver = connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    self?.latestConnectionTask = Task { [weak self] in
                        guard let self else { return }
                        await onConnected()
                    }
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
        cacheState = .cold
        authState = .unknown
        recentRepos = []
        ownRepos = []
        branchStates = [:]
        lastError = nil
    }

    /// Single-flight: a load already in flight is joined, not duplicated.
    private func startLoad(silent: Bool) {
        if cacheState == .cold { cacheState = .failedCold }
        guard loadTask == nil else { return }
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.runLoad(silent: silent, generation: generation)
            guard let self, loadGeneration == generation else { return }
            loadTask = nil
        }
        latestLoadTask = loadTask
    }

    private func runLoad(silent: Bool, generation: Int) async {
        // The task may first run after an invalidate() that superseded it:
        // touch nothing (an `isLoading` set here would never be cleared).
        guard generation == loadGeneration else { return }
        if !silent { cacheState = .loadingCold }
        lastError = nil
        // Recents come from the daemon registry (no GitHub round-trip), so
        // fetch them concurrently with the auth-gated GitHub list.
        async let recents: Void = fetchRecentRepos(generation: generation)
        let configured = await fetchAuthStatus(generation: generation)
        guard generation == loadGeneration else { return }
        // A transport error on the auth read fails the load: cached auth and
        // lists stay as they were, and a cold load is retried next time.
        var succeeded = configured != nil
        if configured == true {
            succeeded = await fetchOwnRepos(generation: generation)
        }
        await recents
        guard generation == loadGeneration else { return }
        if succeeded {
            cacheState = .loaded(Date())
        } else if !silent {
            cacheState = .failedCold
        }
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
            authState = configured ? .configured : .unconfigured
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
        activeSearchCount += 1
        lastError = nil
        defer { activeSearchCount -= 1 }
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
}
