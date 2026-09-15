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

    /// A fake whose three load reads answer immediately with one recent and
    /// one own repo, plus a store that has completed its cold load over it.
    private func makeLoadedStore(
        configured: Bool = true
    ) async -> (store: GitHubRepoStore, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        fake.responseMap["github.authStatus"] = ["isConfigured": configured]
        fake.responseMap["repo.list"] = ["repos": [
            ["path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
             "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"],
        ]]
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict(name: "cached")]]
        let store = GitHubRepoStore(connectionManager: fake)
        await store.loadIfNeeded()
        return (store, fake)
    }

    /// Poll (bounded) until the condition holds — avoids fixed-sleep
    /// flakiness for assertions on Task-spawned background refreshes.
    /// Records a failure on timeout so a missed update cannot pass silently.
    private func waitFor(_ description: String = "condition", _ condition: () -> Bool) async throws {
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

    @Test func fetchAuthStatusErrorReturnsNilAndKeepsIsConfigured() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        store.isConfigured = true
        fake.errorMap["github.authStatus"] = NSError(
            domain: "t", code: -1,
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
                ["path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
                 "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"],
                ["path": "/repos/local-only", "name": "local-only",
                 "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-09T10:00:00Z"],
                ["path": "/repos/intentd", "name": "intentd", "owner": "intent-hq",
                 "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-08T10:00:00Z"],
            ]
        ]
        await store.fetchRecentRepos()
        #expect(store.recentRepos.map(\.fullName) == ["intent-hq/monorepo", "intent-hq/intentd"])
    }

    @Test func fetchRecentReposErrorLeavesRecentsUnchanged() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        let existing = GitHubRepo.parseRepo(makeRepoDict())!
        store.recentRepos = [existing]
        fake.errorMap["repo.list"] = NSError(domain: "t", code: -1)
        await store.fetchRecentRepos()
        #expect(store.recentRepos == [existing])
    }

    @Test func fetchRecentReposMalformedResponseLeavesRecentsUnchanged() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        let existing = GitHubRepo.parseRepo(makeRepoDict())!
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
            "nextToken": "tok-1",
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

    @Test func searchReposReturnsPerCallerResultsWithoutTouchingSharedLists() async {
        // The store is shared by every picker on the session, so search
        // results are returned to the caller (per-view state) and never
        // stored: two pickers searching different queries each get their
        // own answer and the cached lists stay untouched.
        let (store, fake) = await makeLoadedStore()
        let cachedRecents = store.recentRepos
        let cachedOwn = store.ownRepos
        fake.responseMap["github.repos.search"] = ["repos": [makeRepoDict(name: "alpha")]]
        let first = await store.searchRepos(query: "alpha")
        fake.responseMap["github.repos.search"] = ["repos": [makeRepoDict(name: "beta")]]
        let second = await store.searchRepos(query: "beta")
        #expect(first?.map(\.name) == ["alpha"])
        #expect(second?.map(\.name) == ["beta"])
        #expect(store.recentRepos == cachedRecents)
        #expect(store.ownRepos == cachedOwn)
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

    // MARK: - loadIfNeeded (session cache, stale-while-revalidate)

    @Test func coldLoadIssuesAllReadsAndMarksLoaded() async {
        let (store, fake) = await makeLoadedStore()
        #expect(store.hasCheckedAuth)
        #expect(store.isConfigured)
        #expect(store.hasLoaded)
        #expect(store.lastLoadedAt != nil)
        #expect(store.isLoading == false)
        #expect(store.recentRepos.map(\.fullName) == ["intent-hq/monorepo"])
        #expect(store.ownRepos.map(\.name) == ["cached"])
        #expect(fake.paramsForMethod("github.authStatus").count == 1)
        #expect(fake.paramsForMethod("repo.list").count == 1)
        #expect(fake.paramsForMethod("github.repos.list").count == 1)
    }

    @Test func coldLoadNotConfiguredSkipsOwnReposButIsStillLoaded() async {
        let (store, fake) = await makeLoadedStore(configured: false)
        #expect(store.hasCheckedAuth)
        #expect(store.isConfigured == false)
        #expect(store.hasLoaded)
        #expect(store.ownRepos.isEmpty)
        #expect(fake.didCallMethod("github.repos.list") == false)
    }

    @Test func secondLoadIfNeededKeepsDataAndRevalidatesSilently() async throws {
        let (store, fake) = await makeLoadedStore()
        let cachedRecents = store.recentRepos
        let cachedOwn = store.ownRepos
        // Keep the refresh's GitHub read in flight so the mid-refresh state
        // is observable.
        fake.pendingMethods = ["github.repos.list"]

        await store.loadIfNeeded()

        // Returned immediately with the cache intact; the background refresh
        // still issues its reads but never flips the spinner.
        try await waitFor {
            fake.paramsForMethod("github.repos.list").count == 2
                && fake.paramsForMethod("repo.list").count == 2
        }
        #expect(store.isLoading == false)
        #expect(store.hasLoaded)
        #expect(store.recentRepos == cachedRecents)
        #expect(store.ownRepos == cachedOwn)
        #expect(fake.paramsForMethod("github.authStatus").count == 2)

        // The refresh lands in place once it resolves.
        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "fresh")]])
        try await waitFor { store.ownRepos.map(\.name) == ["fresh"] }
        #expect(store.isLoading == false)
    }

    @Test func concurrentColdLoadsShareOneFlight() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        fake.responseMap["repo.list"] = ["repos": []]
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict()]]
        let store = GitHubRepoStore(connectionManager: fake)

        async let first: Void = store.loadIfNeeded()
        async let second: Void = store.loadIfNeeded()
        _ = await (first, second)

        #expect(store.hasLoaded)
        #expect(fake.paramsForMethod("github.authStatus").count == 1)
        #expect(fake.paramsForMethod("github.repos.list").count == 1)
    }

    @Test func forceRefetchesEvenWhenCached() async {
        let (store, fake) = await makeLoadedStore()
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict(name: "fresh")]]

        await store.loadIfNeeded(force: true)

        #expect(fake.paramsForMethod("github.repos.list").count == 2)
        #expect(store.ownRepos.map(\.name) == ["fresh"])
        #expect(store.hasLoaded)
        #expect(store.isLoading == false)
    }

    @Test func failedBackgroundRefreshKeepsCachedLists() async {
        let (store, fake) = await makeLoadedStore()
        let cachedOwn = store.ownRepos
        fake.errorMap["github.repos.list"] = NSError(
            domain: "t", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "rate limited"]
        )

        await store.loadIfNeeded(force: true)

        #expect(store.ownRepos == cachedOwn)
        #expect(store.lastError == "rate limited")
        #expect(store.hasLoaded)
    }

    @Test func failedColdLoadLeavesHasLoadedFalseSoNextCallRetries() async {
        let fake = FakeConnectionManager()
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        fake.responseMap["repo.list"] = ["repos": []]
        fake.errorMap["github.repos.list"] = NSError(domain: "t", code: -1)
        let store = GitHubRepoStore(connectionManager: fake)

        await store.loadIfNeeded()
        #expect(store.hasCheckedAuth)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)

        fake.errorMap.removeValue(forKey: "github.repos.list")
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict()]]
        await store.loadIfNeeded()
        #expect(store.hasLoaded)
        #expect(store.ownRepos.count == 1)
        #expect(fake.paramsForMethod("github.repos.list").count == 2)
    }

    @Test func coldAuthErrorIsNotLoadedAndKeepsAuthUnknown() async {
        let fake = FakeConnectionManager()
        fake.errorMap["github.authStatus"] = NSError(
            domain: "t", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "socket closed"]
        )
        fake.responseMap["repo.list"] = ["repos": []]
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict()]]
        let store = GitHubRepoStore(connectionManager: fake)

        await store.loadIfNeeded()

        // Auth is unknown, not "not configured": the picker must not show
        // not-connected guidance, and the load is not treated as complete.
        #expect(store.hasCheckedAuth == false)
        #expect(store.isConfigured == false)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.lastError == "socket closed")
        #expect(store.isLoading == false)
        #expect(fake.didCallMethod("github.repos.list") == false)

        // The next call retries as a cold load.
        fake.errorMap.removeValue(forKey: "github.authStatus")
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        await store.loadIfNeeded()
        #expect(store.hasCheckedAuth)
        #expect(store.isConfigured)
        #expect(store.hasLoaded)
        #expect(store.lastError == nil)
        #expect(store.ownRepos.count == 1)
    }

    @Test func cachedAuthErrorOnRefreshKeepsConnectedCache() async throws {
        let (store, fake) = await makeLoadedStore()
        let cachedRecents = store.recentRepos
        let cachedOwn = store.ownRepos
        fake.errorMap["github.authStatus"] = NSError(
            domain: "t", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "socket closed"]
        )
        fake.clearRequestLog()

        await store.loadIfNeeded(force: true)

        // A transport failure on the auth read must not flip the cached
        // picker to not-connected guidance or drop its lists.
        #expect(store.isConfigured == true)
        #expect(store.hasCheckedAuth)
        #expect(store.hasLoaded)
        #expect(store.recentRepos == cachedRecents)
        #expect(store.ownRepos == cachedOwn)
        #expect(store.lastError == "socket closed")
        #expect(store.isLoading == false)
        #expect(fake.didCallMethod("github.repos.list") == false)

        // The same holds for the silent revalidation on a cached reopen.
        fake.clearRequestLog()
        await store.loadIfNeeded()
        try await waitFor { fake.didCallMethod("github.authStatus") }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isConfigured == true)
        #expect(store.ownRepos == cachedOwn)
    }

    @Test func invalidateEmptiesListsAndResetsHasLoaded() async {
        let (store, _) = await makeLoadedStore()

        store.invalidate()

        #expect(store.recentRepos.isEmpty)
        #expect(store.ownRepos.isEmpty)
        #expect(store.isConfigured == false)
        #expect(store.hasCheckedAuth == false)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.lastError == nil)
    }

    @Test func loadAfterInvalidateRunsCold() async {
        let (store, fake) = await makeLoadedStore()
        store.invalidate()
        fake.clearRequestLog()

        await store.loadIfNeeded()

        #expect(store.hasLoaded)
        #expect(store.ownRepos.map(\.name) == ["cached"])
        #expect(fake.paramsForMethod("github.repos.list").count == 1)
    }

    @Test func invalidateDuringPendingRefreshRejectsStaleCompletion() async throws {
        let (store, fake) = await makeLoadedStore()
        // A silent refresh whose GitHub read is still in flight.
        fake.pendingMethods = ["github.repos.list"]
        await store.loadIfNeeded()
        try await waitFor("refresh read") { fake.paramsForMethod("github.repos.list").count == 2 }

        store.invalidate()
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)

        // The superseded refresh completes with data from before the
        // invalidation: it must not repopulate the cache or mark it loaded.
        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "stale")]])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.ownRepos.isEmpty)
        #expect(store.recentRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)

        // The next call starts a fresh cold load rather than joining the
        // superseded flight.
        fake.pendingMethods = []
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict(name: "fresh")]]
        await store.loadIfNeeded()
        #expect(store.ownRepos.map(\.name) == ["fresh"])
        #expect(store.hasLoaded)
        #expect(fake.paramsForMethod("github.repos.list").count == 3)
    }

    @Test func loadTaskStartingAfterInvalidateTouchesNothing() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.clearRequestLog()
        // The cached path spawns a silent refresh task and returns without
        // suspending, so this invalidate() runs before that task's first
        // line: the task must exit at entry instead of issuing reads.
        await store.loadIfNeeded()
        store.invalidate()

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.requestLog.isEmpty)
        #expect(store.isLoading == false)
        #expect(store.hasLoaded == false)
        #expect(store.hasCheckedAuth == false)
        #expect(store.ownRepos.isEmpty)
        #expect(store.recentRepos.isEmpty)

        // The cache is not left in a stuck state: a fresh cold load runs.
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict(name: "fresh")]]
        await store.loadIfNeeded()
        #expect(store.hasLoaded)
        #expect(store.isLoading == false)
        #expect(store.ownRepos.map(\.name) == ["fresh"])
        #expect(fake.paramsForMethod("github.repos.list").count == 1)
    }

    // MARK: - Reconnect

    @Test func reconnectAfterFailedColdLoadClearsPartialCacheAndRetries() async throws {
        let fake = FakeConnectionManager()
        fake.errorMap["github.authStatus"] = NSError(domain: "t", code: -1)
        fake.responseMap["repo.list"] = ["repos": [
            ["path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
             "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"],
        ]]
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict(name: "fresh")]]
        let store = GitHubRepoStore(connectionManager: fake)
        await store.loadIfNeeded()
        // A failed cold load: recents landed, auth did not, nothing in flight.
        #expect(store.recentRepos.map(\.fullName) == ["intent-hq/monorepo"])
        #expect(store.hasLoaded == false)
        #expect(store.lastError != nil)

        fake.errorMap["github.authStatus"] = nil
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        fake.pendingMethods = ["github.authStatus", "repo.list"]
        fake.clearRequestLog()

        fake.simulateConnect()

        // The reconnect still hard-clears the partial cache and retries.
        try await waitFor("retry reads") {
            fake.didCallMethod("github.authStatus") && fake.didCallMethod("repo.list")
        }
        #expect(store.recentRepos.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        fake.resolvePending("github.authStatus", with: ["isConfigured": true])
        fake.resolvePending("repo.list", with: ["repos": [
            ["path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
             "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"],
        ]])
        try await waitFor("retry completion") { store.hasLoaded }
        #expect(store.hasCheckedAuth)
        #expect(store.isConfigured)
        #expect(store.ownRepos.map(\.name) == ["fresh"])
        #expect(store.recentRepos.map(\.fullName) == ["intent-hq/monorepo"])
        #expect(store.lastError == nil)
        #expect(store.isLoading == false)
    }

    @Test func reconnectHardClearsCacheThenReloadsCold() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict(name: "fresh")]]
        // Hold the reload's first reads so the cleared state is observable
        // before any fresh data lands.
        fake.pendingMethods = ["github.authStatus", "repo.list"]
        fake.clearRequestLog()

        fake.simulateConnect()

        try await waitFor("reload reads") {
            fake.didCallMethod("github.authStatus") && fake.didCallMethod("repo.list")
        }
        // Stale lists are gone before the reload answers; the picker shows
        // the cold spinner rather than a stale list.
        #expect(store.recentRepos.isEmpty)
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.hasCheckedAuth == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading)

        fake.resolvePending("github.authStatus", with: ["isConfigured": true])
        fake.resolvePending("repo.list", with: ["repos": [
            ["path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
             "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"],
        ]])
        try await waitFor("reload completion") { store.hasLoaded }
        #expect(store.ownRepos.map(\.name) == ["fresh"])
        #expect(store.recentRepos.map(\.fullName) == ["intent-hq/monorepo"])
        #expect(store.hasCheckedAuth)
        #expect(store.isConfigured)
        #expect(store.isLoading == false)
        #expect(fake.paramsForMethod("github.repos.list").count == 1)
    }

    @Test func reconnectDoesNotJoinOrApplyPreReconnectRefresh() async throws {
        let (store, fake) = await makeLoadedStore()
        // A silent refresh whose GitHub read is still in flight when the
        // connection flaps.
        fake.pendingMethods = ["github.repos.list"]
        await store.loadIfNeeded()
        try await waitFor("pre-reconnect read") { fake.paramsForMethod("github.repos.list").count == 2 }

        fake.simulateConnect()

        // The reconnect starts its own cold load instead of joining the
        // superseded flight, and the cache is already cleared.
        try await waitFor("reconnect read") { fake.paramsForMethod("github.repos.list").count == 3 }
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        // The pre-reconnect read resolves first (oldest pending) with stale
        // data: dropped.
        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "stale")]])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        // The reconnect's own read lands.
        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "fresh")]])
        try await waitFor("reconnect completion") { store.hasLoaded }
        #expect(store.ownRepos.map(\.name) == ["fresh"])
        #expect(store.isLoading == false)
    }

    @Test func reconnectWithoutCacheDoesNotFetch() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        fake.responseMap["repo.list"] = ["repos": []]
        fake.responseMap["github.repos.list"] = ["repos": []]
        let store = GitHubRepoStore(connectionManager: fake)

        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)
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
            "nextToken": "tok-1",
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
            owner: "intent-hq", repo: "intentd", prefix: "feature/"
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

    // MARK: - fetchCachedBranches (github.branches.listCached)

    @Test func fetchCachedBranchesReadsListCached() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.listCached"] = [
            "cached": true, "source": "cache",
            "branches": ["dev", "main"], "defaultBranch": "main",
        ]
        let listing = await store.fetchCachedBranches(owner: "intent-hq", repo: "intentd")
        #expect(listing == GitHubBranchListing(branches: ["dev", "main"], defaultBranch: "main"))
        let calls = fake.paramsForMethod("github.branches.listCached")
        #expect(calls.count == 1)
        #expect(calls[0]["owner"] as? String == "intent-hq")
        #expect(calls[0]["repo"] as? String == "intentd")
        // A first paint only: never promoted to the authoritative cache.
        #expect(store.cachedBranchListing(owner: "intent-hq", repo: "intentd") == nil)
    }

    @Test func fetchCachedBranchesOmittedDefaultBranchIsNil() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.listCached"] = [
            "cached": false, "source": "ls-remote", "branches": ["main"],
        ]
        let listing = await store.fetchCachedBranches(owner: "o", repo: "r")
        #expect(listing == GitHubBranchListing(branches: ["main"], defaultBranch: nil))
    }

    @Test func fetchCachedBranchesColdMissIsNil() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.listCached"] = ["cached": false, "branches": [String]()]
        let listing = await store.fetchCachedBranches(owner: "o", repo: "r")
        #expect(listing == nil)
    }

    @Test func fetchCachedBranchesMethodNotFoundIsMiss() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        // Older daemon without the method (-32601) — a miss, never an error.
        fake.errorMap["github.branches.listCached"] = NSError(
            domain: "WebSocket", code: -32601,
            userInfo: [NSLocalizedDescriptionKey: "Method not found"])
        let listing = await store.fetchCachedBranches(owner: "o", repo: "r")
        #expect(listing == nil)
        #expect(store.lastError == nil)
    }

    // MARK: - loadBranchListing (per-session branch cache)

    @Test func loadBranchListingCachesAuthoritativeListing() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.list"] = ["branches": ["main", "dev"]]

        let listing = try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")

        #expect(listing == GitHubBranchListing(branches: ["main", "dev"], defaultBranch: "main"))
        #expect(store.cachedBranchListing(owner: "o", repo: "other") == nil)
        // A known default branch skips the github.repos.get round-trip.
        #expect(!fake.didCallMethod("github.repos.get"))
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState(listing: listing))
        // The cache hit is synchronous: no request behind it.
        try await Task.sleep(nanoseconds: 20_000_000)
        fake.clearRequestLog()
        #expect(store.cachedBranchListing(owner: "o", repo: "r") == listing)
        #expect(fake.requestLog.isEmpty)
    }

    @Test func coldBranchLoadPaintsListCachedUntilAuthoritativeLands() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.pendingMethods = ["github.branches.listCached", "github.branches.list"]

        let load = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("both reads") {
            fake.didCallMethod("github.branches.listCached") && fake.didCallMethod("github.branches.list")
        }
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState())

        fake.resolvePending("github.branches.listCached", with: ["cached": true, "branches": ["main", "old"]])
        try await waitFor("paint") { store.branchState(owner: "o", repo: "r").paint != nil }
        let painted = store.branchState(owner: "o", repo: "r")
        #expect(painted.displayed == GitHubBranchListing(branches: ["main", "old"], defaultBranch: nil))
        #expect(painted.listing == nil)
        #expect(store.cachedBranchListing(owner: "o", repo: "r") == nil)

        fake.resolvePending("github.branches.list", with: ["branches": ["main", "new"]])
        let listing = try await load.value
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState(listing: listing))
        #expect(listing.branches == ["main", "new"])
    }

    @Test func lateListCachedAnswerNeverOverridesAuthoritativeOutcome() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.pendingMethods = ["github.branches.listCached"]
        fake.responseMap["github.branches.list"] = ["branches": ["main"]]

        let listing = try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        try await waitFor("paint read") { fake.didCallMethod("github.branches.listCached") }
        fake.resolvePending("github.branches.listCached", with: ["cached": true, "branches": ["stale"]])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState(listing: listing))
    }

    @Test func coldBranchLoadFailurePublishesErrorAndDropsPaint() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        // The paint answers at once; the authoritative read fails later.
        fake.responseMap["github.branches.listCached"] = ["cached": true, "branches": ["main"]]
        fake.delayMap["github.branches.list"] = 100_000_000
        fake.errorMap["github.branches.list"] = NSError(
            domain: "t", code: -1, userInfo: [NSLocalizedDescriptionKey: "offline"])

        let load = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("paint") { store.branchState(owner: "o", repo: "r").paint != nil }
        await #expect(throws: (any Error).self) { try await load.value }

        let state = store.branchState(owner: "o", repo: "r")
        #expect(state.error == "offline")
        #expect(state.displayed == nil)
        #expect(state.listing == nil)
        // Retry from another consumer: the error clears for everyone.
        fake.errorMap["github.branches.list"] = nil
        fake.responseMap["github.branches.list"] = ["branches": ["main"]]
        let listing = try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState(listing: listing))
    }

    @Test func coldBranchLoadErrorClearsWhenAnotherConsumerSucceeds() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.branches.list"] = NSError(
            domain: "t", code: -1, userInfo: [NSLocalizedDescriptionKey: "offline"])
        // Sheet A: cold load fails.
        await #expect(throws: (any Error).self) {
            try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        }
        #expect(store.branchState(owner: "o", repo: "r").error == "offline")

        // Sheet B on the same session fills the store.
        fake.errorMap["github.branches.list"] = nil
        fake.responseMap["github.branches.list"] = ["branches": ["main"]]
        let listing = try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")

        // Sheet A reads the same state: listing shown, no stuck error.
        let state = store.branchState(owner: "o", repo: "r")
        #expect(state.error == nil)
        #expect(state.displayed == listing)
    }

    @Test func loadBranchListingResolvesUnknownDefaultBranch() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.repos.get"] = ["repo": makeRepoDict(defaultBranch: "develop")]
        fake.responseMap["github.branches.list"] = ["branches": ["develop", "main"]]

        let listing = try await store.loadBranchListing(owner: "o", repo: "r")

        #expect(listing.defaultBranch == "develop")
        #expect(fake.paramsForMethod("github.repos.get").count == 1)
    }

    @Test func loadBranchListingFailureKeepsCachedListingAndThrows() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.list"] = ["branches": ["main"]]
        let cached = try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        fake.errorMap["github.branches.list"] = NSError(domain: "t", code: -1)

        await #expect(throws: (any Error).self) {
            try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        }
        // A failed refresh is silent: the listing stays, no error is shown.
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState(listing: cached))
    }

    @Test func concurrentBranchLoadsShareOneFlight() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.pendingMethods = ["github.branches.list"]

        async let first = store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        async let second = store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        try await waitFor("branch read") { fake.paramsForMethod("github.branches.list").count == 1 }
        fake.resolvePending("github.branches.list", with: ["branches": ["main"]])

        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(fake.paramsForMethod("github.branches.list").count == 1)
    }

    @Test func invalidateClearsBranchCacheAndDropsInFlightCompletion() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.list"] = ["branches": ["main"]]
        try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        fake.pendingMethods = ["github.branches.list"]
        let inFlight = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("refresh read") { fake.paramsForMethod("github.branches.list").count == 2 }

        store.invalidate()
        #expect(store.cachedBranchListing(owner: "o", repo: "r") == nil)

        fake.resolvePending("github.branches.list", with: ["branches": ["stale"]])
        _ = try await inFlight.value
        // The pre-invalidate completion is answered but never re-cached.
        #expect(store.cachedBranchListing(owner: "o", repo: "r") == nil)
    }

    // MARK: - Reconnect (connection lifecycle, not manual invalidate)

    @Test func reconnectDuringColdBranchLoadClearsStateAndDropsOldCompletion() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.pendingMethods = ["github.branches.list"]
        let generation = store.loadGeneration
        let inFlight = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("cold read") { fake.paramsForMethod("github.branches.list").count == 1 }

        fake.simulateConnect()
        try await waitFor("hard clear") { store.loadGeneration != generation }
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState())

        // The old flight is no longer joined: a fresh load issues its own read.
        let fresh = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("fresh read") { fake.paramsForMethod("github.branches.list").count == 2 }

        fake.resolvePending("github.branches.list", with: ["branches": ["stale"]])
        _ = try await inFlight.value
        #expect(store.cachedBranchListing(owner: "o", repo: "r") == nil)

        fake.resolvePending("github.branches.list", with: ["branches": ["fresh"]])
        let listing = try await fresh.value
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState(listing: listing))
        #expect(listing.branches == ["fresh"])
    }

    @Test func reconnectClearsFirstPaintOnlyState() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.pendingMethods = ["github.branches.list"]
        fake.responseMap["github.branches.listCached"] = ["cached": true, "branches": ["main"]]
        let generation = store.loadGeneration
        _ = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("paint") { store.branchState(owner: "o", repo: "r").paint != nil }

        fake.simulateConnect()
        try await waitFor("hard clear") { store.loadGeneration != generation }

        #expect(store.branchState(owner: "o", repo: "r").displayed == nil)
        // The old flight's answer is dropped, not published.
        fake.resolvePending("github.branches.list", with: ["branches": ["stale"]])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState())
    }

    @Test func reconnectClearsPriorBranchError() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["github.branches.list"] = NSError(domain: "t", code: -1)
        await #expect(throws: (any Error).self) {
            try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        }
        #expect(store.branchState(owner: "o", repo: "r").error != nil)
        let generation = store.loadGeneration

        fake.simulateConnect()
        try await waitFor("hard clear") { store.loadGeneration != generation }

        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState())
    }

    @Test func lateListCachedAnswerFromBeforeReconnectNeverLands() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.pendingMethods = ["github.branches.listCached", "github.branches.list"]
        let generation = store.loadGeneration
        _ = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("paint read") { fake.didCallMethod("github.branches.listCached") }

        fake.simulateConnect()
        try await waitFor("hard clear") { store.loadGeneration != generation }
        // The new connection's cold load is in flight again (state reset).
        _ = Task { try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main") }
        try await waitFor("fresh reads") { fake.paramsForMethod("github.branches.list").count == 2 }

        fake.resolvePending("github.branches.listCached", with: ["cached": true, "branches": ["old-paint"]])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.branchState(owner: "o", repo: "r").paint == nil)

        // The new connection's own paint still lands.
        fake.resolvePending("github.branches.listCached", with: ["cached": true, "branches": ["new-paint"]])
        try await waitFor("new paint") { store.branchState(owner: "o", repo: "r").paint != nil }
        #expect(store.branchState(owner: "o", repo: "r").paint?.branches == ["new-paint"])
        fake.resolvePending("github.branches.list", with: ["branches": ["stale"]])
        fake.resolvePending("github.branches.list", with: ["branches": ["main"]])
        try await waitFor("authoritative") { store.cachedBranchListing(owner: "o", repo: "r") != nil }
        #expect(store.branchState(owner: "o", repo: "r") == GitHubBranchLoadState(
            listing: GitHubBranchListing(branches: ["main"], defaultBranch: "main")))
    }

    @Test func reconnectClearsWarmDedupSoTheSelectedRepoRewarms() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["repo.warmCache"] = ["started": true, "owner": "o", "repo": "r"]
        fake.responseMap["github.branches.list"] = ["branches": ["main"]]
        try await store.loadBranchListing(owner: "o", repo: "r", defaultBranch: "main")
        let generation = store.loadGeneration

        store.warmRepoCache(owner: "o", repo: "r")
        store.warmRepoCache(owner: "o", repo: "r")
        try await waitFor("first warm") { fake.paramsForMethod("repo.warmCache").count == 1 }

        fake.simulateConnect()
        try await waitFor("hard clear") { store.loadGeneration != generation }
        // The branch step reloads and re-warms on the new connection: exactly
        // one more request, deduplicated again within it.
        store.warmRepoCache(owner: "o", repo: "r")
        store.warmRepoCache(owner: "o", repo: "r")
        try await waitFor("second warm") { fake.paramsForMethod("repo.warmCache").count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fake.paramsForMethod("repo.warmCache").count == 2)
    }

    // MARK: - warmRepoCache (repo.warmCache)

    @Test func warmRepoCacheSendsGithubUrlOncePerRepo() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["repo.warmCache"] = ["started": true, "owner": "intent-hq", "repo": "intentd"]

        store.warmRepoCache(owner: "intent-hq", repo: "intentd")
        store.warmRepoCache(owner: "intent-hq", repo: "intentd")
        store.warmRepoCache(owner: "intent-hq", repo: "ios")
        try await waitFor("warm requests") { fake.paramsForMethod("repo.warmCache").count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)

        let calls = fake.paramsForMethod("repo.warmCache")
        #expect(calls.count == 2)
        #expect(calls[0]["githubUrl"] as? String == "https://github.com/intent-hq/intentd")
        #expect(calls[1]["githubUrl"] as? String == "https://github.com/intent-hq/ios")
        #expect(calls[0].count == 1)
    }

    @Test func warmRepoCacheErrorIsSwallowed() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.errorMap["repo.warmCache"] = NSError(
            domain: "WebSocket", code: -32603,
            userInfo: [NSLocalizedDescriptionKey: "repo cache warm already in flight for o/r"])

        store.warmRepoCache(owner: "o", repo: "r")
        try await waitFor("warm request") { fake.didCallMethod("repo.warmCache") }
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(store.lastError == nil)
    }

    @Test func warmRepoCacheRearmsAfterInvalidate() async throws {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["repo.warmCache"] = ["started": true, "owner": "o", "repo": "r"]

        store.warmRepoCache(owner: "o", repo: "r")
        try await waitFor("first warm") { fake.paramsForMethod("repo.warmCache").count == 1 }
        store.invalidate()
        store.warmRepoCache(owner: "o", repo: "r")
        try await waitFor("second warm") { fake.paramsForMethod("repo.warmCache").count == 2 }
    }
}
