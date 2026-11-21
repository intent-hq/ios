import Combine
import Foundation
import Observation

enum GitHubRepoSearchOutcome {
    case failed
    case results([GitHubRepo])
}

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
    var branchStates: [String: GitHubBranchLoadState] = [:]
    var isLoading: Bool { cacheState == .loadingCold || activeSearchCount > 0 }
    var lastError: String?
    var hasCheckedAuth: Bool { authState != .unknown }
    var hasLoaded: Bool {
        if case .loaded = cacheState { return true }
        return false
    }
    var lastLoadedAt: Date? {
        if case let .loaded(date) = cacheState { return date }
        return nil
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var latestLoadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var latestConnectionTask: Task<Void, Never>?
    @ObservationIgnored var latestBranchPaintTask: Task<Void, Never>?
    private(set) var loadGeneration = 0
    private var hasAttemptedLoad: Bool {
        cacheState != .cold || !branchStates.isEmpty || !branchLoadTasks.isEmpty
    }
    @ObservationIgnored var branchLoadTasks: [String: Task<GitHubBranchListing, Error>] = [:]
    @ObservationIgnored var warmedRepos: Set<String> = []
    @ObservationIgnored private var connectionObserver: AnyCancellable?

    static let pageLimit = 100
    static let ownReposLimit = 50
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

    func loadIfNeeded(force: Bool = false) async {
        guard force || !hasLoaded else {
            startLoad(silent: true)
            return
        }
        startLoad(silent: hasLoaded)
        await loadTask?.value
    }

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
        guard generation == loadGeneration else { return }
        if !silent { cacheState = .loadingCold }
        lastError = nil
        async let recents: Void = fetchRecentRepos(generation: generation)
        let configured = await fetchAuthStatus(generation: generation)
        guard generation == loadGeneration else { return }
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

    private func onConnected() async {
        guard hasAttemptedLoad else { return }
        invalidate()
        await loadIfNeeded()
    }

    // MARK: - Auth

    @discardableResult
    // swiftlint:disable:next discouraged_optional_boolean
    func fetchAuthStatus() async -> Bool? {
        await fetchAuthStatus(generation: loadGeneration)
    }

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
