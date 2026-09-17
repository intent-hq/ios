import Foundation
@testable import Intent
import Testing

@MainActor
struct GitHubRepoStoreTests {
    func repoResult(_ outcome: GitHubRepoSearchOutcome) -> (repos: [GitHubRepo], failed: Bool) {
        switch outcome {
        case .failed: ([], true)
        case .results(let repos): (repos, false)
        }
    }

    func makeRepoDict(
        owner: String = "intent-hq",
        name: String = "intentd",
        htmlUrl: String? = "https://github.com/intent-hq/intentd",
        defaultBranch: String? = "main",
        updatedAt: String? = "2026-08-01T10:00:00Z"
    ) -> [String: Any] {
        var dict: [String: Any] = ["owner": owner, "name": name]
        if let htmlUrl { dict["htmlUrl"] = htmlUrl }
        if let defaultBranch { dict["defaultBranch"] = defaultBranch }
        if let updatedAt { dict["updatedAt"] = updatedAt }
        return dict
    }

    /// A fake whose three load reads answer immediately with one recent and
    /// one own repo, plus a store that has completed its cold load over it.
    func makeLoadedStore(
        configured: Bool = true
    ) async -> (store: GitHubRepoStore, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        fake.responseMap["github.authStatus"] = ["isConfigured": configured]
        fake.responseMap["repo.list"] = [
            "repos": [
                [
                    "path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
                    "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"
                ]
            ]
        ]
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict(name: "cached")]]
        let store = GitHubRepoStore(connectionManager: fake)
        await store.loadIfNeeded()
        return (store, fake)
    }

    /// Poll (bounded) until the condition holds — avoids fixed-sleep
    /// flakiness for assertions on Task-spawned background refreshes.
    /// Records a failure on timeout so a missed update cannot pass silently.
    func waitFor(_ description: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(description)")
    }

    // MARK: - Model parsing

    @Test func parsesFullRepo() throws {
        let repo = try #require(GitHubRepo.parseRepo(makeRepoDict()))
        #expect(repo.owner == "intent-hq")
        #expect(repo.name == "intentd")
        #expect(repo.htmlUrl == "https://github.com/intent-hq/intentd")
        #expect(repo.defaultBranch == "main")
        #expect(repo.updatedAt == "2026-08-01T10:00:00Z")
        #expect(repo.fullName == "intent-hq/intentd")
        #expect(repo.id == "intent-hq/intentd")
    }

    @Test func parsesRepoWithMissingOptionals() throws {
        let repo = try #require(GitHubRepo.parseRepo(["owner": "o", "name": "n"]))
        #expect(repo.htmlUrl == nil)
        #expect(repo.defaultBranch == nil)
        #expect(repo.updatedAt == nil)
    }

    @Test func rejectsMissingOrEmptyRequiredFields() {
        #expect(GitHubRepo.parseRepo(["name": "n"]) == nil)
        #expect(GitHubRepo.parseRepo(["owner": "o"]) == nil)
        #expect(GitHubRepo.parseRepo(["owner": "", "name": "n"]) == nil)
        #expect(GitHubRepo.parseRepo(["owner": "o", "name": ""]) == nil)
    }

    // MARK: - Query rewrite

    @Test func rewritesOwnerSlashNameQuery() {
        #expect(GitHubRepoStore.rewriteSearchQuery("intent-hq/intentd") == "intentd user:intent-hq")
        #expect(GitHubRepoStore.rewriteSearchQuery("  intent-hq/intentd  ") == "intentd user:intent-hq")
    }

    @Test func rewritesPartialSlashQueries() {
        #expect(GitHubRepoStore.rewriteSearchQuery("intent-hq/") == "user:intent-hq")
        #expect(GitHubRepoStore.rewriteSearchQuery("/intentd") == "intentd")
        #expect(GitHubRepoStore.rewriteSearchQuery("/").isEmpty)
    }

    @Test func leavesBareQueriesUnchanged() {
        #expect(GitHubRepoStore.rewriteSearchQuery("intentd") == "intentd")
        #expect(GitHubRepoStore.rewriteSearchQuery("").isEmpty)
        #expect(GitHubRepoStore.rewriteSearchQuery("   ").isEmpty)
    }

    // MARK: - Auth status

    @Test func fetchAuthStatusReadsIsConfigured() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        let configured = await store.fetchAuthStatus()
        #expect(configured == true)
        #expect(store.isConfigured == true)
        #expect(fake.didCallMethod("github.authStatus"))
    }

    @Test func fetchAuthStatusErrorReturnsNilAndKeepsIsConfigured() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        store.isConfigured = true
        fake.errorMap["github.authStatus"] = NSError(
            domain: "t",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "socket closed"]
        )
        let configured = await store.fetchAuthStatus()
        #expect(configured == nil)
        #expect(store.isConfigured == true)
        #expect(store.lastError == "socket closed")
    }

    // MARK: - fetchRecentRepos

    @Test func fetchRecentReposMapsOwnedEntriesInMRUOrder() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["repo.list"] = [
            "repos": [
                [
                    "path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
                    "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"
                ],
                [
                    "path": "/repos/local-only", "name": "local-only",
                    "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-09T10:00:00Z"
                ],
                [
                    "path": "/repos/intentd", "name": "intentd", "owner": "intent-hq",
                    "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-08T10:00:00Z"
                ]
            ]
        ]
        await store.fetchRecentRepos()
        #expect(store.recentRepos.map(\.fullName) == ["intent-hq/monorepo", "intent-hq/intentd"])
    }

    @Test func fetchRecentReposErrorLeavesRecentsUnchanged() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        let existing = try #require(GitHubRepo.parseRepo(makeRepoDict()))
        store.recentRepos = [existing]
        fake.errorMap["repo.list"] = NSError(domain: "t", code: -1)
        await store.fetchRecentRepos()
        #expect(store.recentRepos == [existing])
    }

    @Test func fetchRecentReposMalformedResponseLeavesRecentsUnchanged() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        let existing = try #require(GitHubRepo.parseRepo(makeRepoDict()))
        store.recentRepos = [existing]
        fake.responseMap["repo.list"] = ["unexpected": "shape"]
        await store.fetchRecentRepos()
        #expect(store.recentRepos == [existing])
    }

    // MARK: - fetchOwnRepos (single page)

    @Test func fetchOwnReposIssuesExactlyOneRequestWithLimit() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.list"] = [
            "repos": [makeRepoDict(name: "a"), makeRepoDict(name: "b")],
            "nextToken": "tok-1"
        ]
        await store.fetchOwnRepos()
        #expect(store.ownRepos.map(\.name) == ["a", "b"])
        #expect(store.lastError == nil)

        // Exactly one request with the 50-repo cap; the nextToken is ignored.
        let calls = fake.paramsForMethod("github.repos.list")
        #expect(calls.count == 1)
        #expect(calls[0]["limit"] as? Int == GitHubRepoStore.ownReposLimit)
        #expect(GitHubRepoStore.ownReposLimit == 50)
        #expect(calls[0]["nextToken"] == nil)
    }

    @Test func fetchOwnReposSkipsUnparsableRows() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.list"] = [
            "repos": [makeRepoDict(), ["name": "missing-owner"]]
        ]
        await store.fetchOwnRepos()
        #expect(store.ownRepos.count == 1)
    }

    @Test func fetchOwnReposErrorSetsLastError() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.repos.list"] = NSError(
            domain: "t",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        await store.fetchOwnRepos()
        #expect(store.ownRepos.isEmpty)
        #expect(store.lastError == "boom")
        #expect(store.isLoading == false)
    }
}

extension GitHubRepoStoreTests {
    // MARK: - searchRepos

    @Test func searchReposSendsRewrittenQuery() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.search"] = ["repos": [makeRepoDict()]]
        let result = repoResult(await store.searchRepos(query: "intent-hq/intentd"))
        let params = fake.paramsForMethod("github.repos.search")
        #expect(params.count == 1)
        #expect(params[0]["query"] as? String == "intentd user:intent-hq")
        #expect(result.repos.count == 1)
        #expect(!result.failed)
    }

    @Test func searchReposSendsBareQueryVerbatim() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.search"] = ["repos": []]
        let result = repoResult(await store.searchRepos(query: "intentd"))
        #expect(fake.paramsForMethod("github.repos.search")[0]["query"] as? String == "intentd")
        #expect(result.repos.isEmpty)
        #expect(!result.failed)
    }

    @Test func searchReposEmptyQueryReturnsEmptyWithoutRequest() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        let result = repoResult(await store.searchRepos(query: "   "))
        #expect(result.repos.isEmpty)
        #expect(!result.failed)
        #expect(fake.didCallMethod("github.repos.search") == false)
    }

    @Test func searchReposReturnsPerCallerResultsWithoutTouchingSharedLists() async {
        // The store is shared by every picker on the session, so search
        // results are returned to the caller (per-view state) and never
        // stored: two pickers searching different queries each get their
        // own answer and the cached lists stay untouched.
        let (store, fake) = await makeLoadedStore()
        let cachedRecents = store.recentRepos
        let cachedOwn = store.ownRepos
        fake.responseMap["github.repos.search"] = ["repos": [makeRepoDict(name: "alpha")]]
        let first = repoResult(await store.searchRepos(query: "alpha"))
        fake.responseMap["github.repos.search"] = ["repos": [makeRepoDict(name: "beta")]]
        let second = repoResult(await store.searchRepos(query: "beta"))
        #expect(first.repos.map(\.name) == ["alpha"])
        #expect(second.repos.map(\.name) == ["beta"])
        #expect(!first.failed && !second.failed)
        #expect(store.recentRepos == cachedRecents)
        #expect(store.ownRepos == cachedOwn)
    }

    @Test func searchReposErrorSetsLastErrorAndReturnsNil() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.repos.search"] = NSError(
            domain: "t",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "search down"]
        )
        let result = repoResult(await store.searchRepos(query: "intentd"))
        #expect(result.failed)
        #expect(result.repos.isEmpty)
        #expect(store.lastError == "search down")
        #expect(store.isLoading == false)
    }

    // MARK: - fetchDefaultBranch

    @Test func fetchDefaultBranchReadsRepoGet() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.get"] = ["repo": makeRepoDict(defaultBranch: "develop")]
        let branch = await store.fetchDefaultBranch(owner: "intent-hq", repo: "intentd")
        #expect(branch == "develop")
        let params = fake.paramsForMethod("github.repos.get")
        #expect(params.count == 1)
        #expect(params[0]["owner"] as? String == "intent-hq")
        #expect(params[0]["repo"] as? String == "intentd")
    }

    @Test func fetchDefaultBranchNilOnNullRepo() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.get"] = ["repo": NSNull()]
        let branch = await store.fetchDefaultBranch(owner: "o", repo: "r")
        #expect(branch == nil)
    }

    @Test func fetchDefaultBranchNilOnError() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.repos.get"] = NSError(domain: "t", code: -1)
        let branch = await store.fetchDefaultBranch(owner: "o", repo: "r")
        #expect(branch == nil)
    }

    // MARK: - fetchRemoteBranches (single page)

    @Test func fetchRemoteBranchesIssuesExactlyOneRequestWithLimit() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.list"] = [
            "branches": ["main", "dev"],
            "nextToken": "tok-1"
        ]
        let branches = try await store.fetchRemoteBranches(owner: "intent-hq", repo: "intentd")
        #expect(branches == ["main", "dev"])

        // Exactly one request with the 50-branch cap; the nextToken is ignored.
        let calls = fake.paramsForMethod("github.branches.list")
        #expect(calls.count == 1)
        #expect(calls[0]["owner"] as? String == "intent-hq")
        #expect(calls[0]["repo"] as? String == "intentd")
        #expect(calls[0]["limit"] as? Int == GitHubRepoStore.branchesLimit)
        #expect(GitHubRepoStore.branchesLimit == 50)
        #expect(calls[0]["nextToken"] == nil)
        #expect(calls[0]["prefix"] == nil)
    }

    @Test func fetchRemoteBranchesSendsPrefixParam() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.list"] = ["branches": ["feature/x"]]
        let branches = try await store.fetchRemoteBranches(
            owner: "intent-hq",
            repo: "intentd",
            prefix: "feature/"
        )
        #expect(branches == ["feature/x"])
        let calls = fake.paramsForMethod("github.branches.list")
        #expect(calls.count == 1)
        #expect(calls[0]["prefix"] as? String == "feature/")
        #expect(calls[0]["limit"] as? Int == GitHubRepoStore.branchesLimit)
    }

    @Test func fetchRemoteBranchesOmitsEmptyPrefix() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.list"] = ["branches": ["main"]]
        _ = try await store.fetchRemoteBranches(owner: "o", repo: "r", prefix: "")
        #expect(fake.paramsForMethod("github.branches.list")[0]["prefix"] == nil)
    }

    @Test func fetchRemoteBranchesThrowsOnTransportError() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.branches.list"] = NSError(domain: "t", code: -1)
        await #expect(throws: (any Error).self) {
            _ = try await store.fetchRemoteBranches(owner: "o", repo: "r")
        }
    }
}
