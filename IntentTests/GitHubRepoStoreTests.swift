import Foundation
import Testing
@testable import Intent

@MainActor
struct GitHubRepoStoreTests {

    private func makeRepoDict(
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
        #expect(GitHubRepoStore.rewriteSearchQuery("/") == "")
    }

    @Test func leavesBareQueriesUnchanged() {
        #expect(GitHubRepoStore.rewriteSearchQuery("intentd") == "intentd")
        #expect(GitHubRepoStore.rewriteSearchQuery("") == "")
        #expect(GitHubRepoStore.rewriteSearchQuery("   ") == "")
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

    @Test func fetchAuthStatusErrorLeavesUnconfigured() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.authStatus"] = NSError(domain: "t", code: -1)
        let configured = await store.fetchAuthStatus()
        #expect(configured == false)
        #expect(store.isConfigured == false)
    }

    // MARK: - fetchOwnRepos pagination

    @Test func fetchOwnReposAccumulatesPages() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseQueueMap["github.repos.list"] = [
            ["repos": [makeRepoDict(name: "a")], "nextToken": "tok-1"],
            ["repos": [makeRepoDict(name: "b")], "nextToken": NSNull()],
        ]
        await store.fetchOwnRepos()
        #expect(store.ownRepos.map(\.name) == ["a", "b"])
        #expect(store.lastError == nil)

        let calls = fake.paramsForMethod("github.repos.list")
        #expect(calls.count == 2)
        #expect(calls[0]["nextToken"] == nil)
        #expect(calls[1]["nextToken"] as? String == "tok-1")
    }

    @Test func fetchOwnReposStopsWhenTokenAbsent() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict()]]
        await store.fetchOwnRepos()
        #expect(store.ownRepos.count == 1)
        #expect(fake.paramsForMethod("github.repos.list").count == 1)
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
            domain: "t", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        await store.fetchOwnRepos()
        #expect(store.ownRepos.isEmpty)
        #expect(store.lastError == "boom")
        #expect(store.isLoading == false)
    }

    // MARK: - searchRepos

    @Test func searchReposSendsRewrittenQuery() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.search"] = ["repos": [makeRepoDict()]]
        let results = await store.searchRepos(query: "intent-hq/intentd")
        let params = fake.paramsForMethod("github.repos.search")
        #expect(params.count == 1)
        #expect(params[0]["query"] as? String == "intentd user:intent-hq")
        #expect(results?.count == 1)
    }

    @Test func searchReposSendsBareQueryVerbatim() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.search"] = ["repos": []]
        let results = await store.searchRepos(query: "intentd")
        #expect(fake.paramsForMethod("github.repos.search")[0]["query"] as? String == "intentd")
        #expect(results?.isEmpty == true)
    }

    @Test func searchReposEmptyQueryReturnsEmptyWithoutRequest() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        let results = await store.searchRepos(query: "   ")
        #expect(results?.isEmpty == true)
        #expect(fake.didCallMethod("github.repos.search") == false)
    }

    @Test func searchReposDoesNotAssignPublishedResults() async {
        // The debounced caller publishes results itself after its
        // cancellation check, so an out-of-order older response can't
        // overwrite a newer one's published results.
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        let existing = GitHubRepo.parseRepo(makeRepoDict())!
        store.searchResults = [existing]
        fake.responseMap["github.repos.search"] = ["repos": [makeRepoDict(name: "other")]]
        _ = await store.searchRepos(query: "other")
        #expect(store.searchResults == [existing])
    }

    @Test func searchReposErrorSetsLastErrorAndReturnsNil() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.repos.search"] = NSError(
            domain: "t", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "search down"]
        )
        let results = await store.searchRepos(query: "intentd")
        #expect(results == nil)
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

    // MARK: - fetchRemoteBranches pagination

    @Test func fetchRemoteBranchesAccumulatesPages() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseQueueMap["github.branches.list"] = [
            ["branches": ["main", "dev"], "nextToken": "tok-1"],
            ["branches": ["feature/x"]],
        ]
        let branches = try await store.fetchRemoteBranches(owner: "intent-hq", repo: "intentd")
        #expect(branches == ["main", "dev", "feature/x"])

        let calls = fake.paramsForMethod("github.branches.list")
        #expect(calls.count == 2)
        #expect(calls[0]["owner"] as? String == "intent-hq")
        #expect(calls[0]["repo"] as? String == "intentd")
        #expect(calls[0]["nextToken"] == nil)
        #expect(calls[1]["nextToken"] as? String == "tok-1")
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
