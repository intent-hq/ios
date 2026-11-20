import Foundation

extension GitHubRepoStore {
    // MARK: - Branches

    func branchState(owner: String, repo: String) -> GitHubBranchLoadState {
        branchStates[Self.branchKey(owner: owner, repo: repo)] ?? GitHubBranchLoadState()
    }

    func cachedBranchListing(owner: String, repo: String) -> GitHubBranchListing? {
        branchStates[Self.branchKey(owner: owner, repo: repo)]?.listing
    }

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

    private func paintCachedBranches(owner: String, repo: String, key: String, generation: Int) {
        latestBranchPaintTask = Task { [self] in
            guard let paint = await fetchCachedBranches(owner: owner, repo: repo),
                  generation == loadGeneration,
                  let state = branchStates[key], state.listing == nil, state.error == nil
            else { return }
            branchStates[key]?.paint = paint
        }
    }

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
