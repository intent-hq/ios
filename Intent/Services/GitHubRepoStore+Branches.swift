import Foundation

extension GitHubRepoStore {
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
        latestBranchPaintTask = Task { [self] in
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
    /// repo per session. Returns the request's task (nil when deduplicated)
    /// so tests can await its completion; callers need not keep it.
    @discardableResult
    func warmRepoCache(owner: String, repo: String) -> Task<Void, Never>? {
        guard warmedRepos.insert(Self.branchKey(owner: owner, repo: repo)).inserted else { return nil }
        return Task { [self] in
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
