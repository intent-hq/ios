import Foundation
@testable import Intent
import Testing

extension GitHubRepoStoreTests {
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
        fake.responseMap["repo.list"] = ["repos": []]
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict()]]
        // Hold the flight's first read so it cannot complete before both
        // callers have entered loadIfNeeded(), whichever order they start
        // in. Without the gate, a flight that finishes before the second
        // caller runs leaves it on the cached path (a silent refresh), which
        // is a second set of reads rather than a shared flight (ios#308).
        fake.pendingMethods = ["github.authStatus"]
        let store = GitHubRepoStore(connectionManager: fake)

        // Each caller checks in immediately before entering loadIfNeeded().
        // It then runs on the main actor without suspending until it awaits
        // the shared flight, so once both check-ins have been received both
        // callers are attached to the flight and the gate can be released.
        let (checkIns, checkIn) = AsyncStream<Void>.makeStream()
        let first = Task {
            checkIn.yield(); await store.loadIfNeeded()
        }
        let second = Task {
            checkIn.yield(); await store.loadIfNeeded()
        }
        var pendingCheckIns = checkIns.makeAsyncIterator()
        _ = await pendingCheckIns.next()
        _ = await pendingCheckIns.next()
        try await waitFor("cold read") { !fake.paramsForMethod("github.authStatus").isEmpty }
        let coldReads = fake.paramsForMethod("github.authStatus").count
        #expect(coldReads == 1)
        #expect(store.isLoading)
        #expect(store.hasLoaded == false)

        // Release every held read, not just one: if a regression ever starts
        // a second flight, the test must fail on the count above rather than
        // hang on a caller whose read was never resumed.
        for _ in 0..<coldReads {
            fake.resolvePending("github.authStatus", with: ["isConfigured": true])
        }
        await first.value
        await second.value

        #expect(store.hasLoaded)
        #expect(store.isLoading == false)
        #expect(fake.paramsForMethod("github.authStatus").count == 1)
        #expect(fake.paramsForMethod("repo.list").count == 1)
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
            domain: "t",
            code: -1,
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
            domain: "t",
            code: -1,
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
            domain: "t",
            code: -1,
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
        await drainMainQueue()
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
        await drainMainQueue()
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

    @Test func loadTaskStartingAfterInvalidateTouchesNothing() async {
        let (store, fake) = await makeLoadedStore()
        fake.clearRequestLog()
        // The cached path spawns a silent refresh task and returns without
        // suspending, so this invalidate() runs before that task's first
        // line: the task must exit at entry instead of issuing reads.
        await store.loadIfNeeded()
        store.invalidate()

        await drainMainQueue()
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
        fake.responseMap["repo.list"] = [
            "repos": [
                [
                    "path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
                    "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"
                ]
            ]
        ]
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
        fake.resolvePending(
            "repo.list",
            with: [
                "repos": [
                    [
                        "path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
                        "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"
                    ]
                ]
            ]
        )
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
        fake.resolvePending(
            "repo.list",
            with: [
                "repos": [
                    [
                        "path": "/repos/monorepo", "name": "monorepo", "owner": "intent-hq",
                        "addedAt": "2026-08-01T10:00:00Z", "lastUsedAt": "2026-08-10T10:00:00Z"
                    ]
                ]
            ]
        )
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
        await drainMainQueue()
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        // The reconnect's own read lands.
        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "fresh")]])
        try await waitFor("reconnect completion") { store.hasLoaded }
        #expect(store.ownRepos.map(\.name) == ["fresh"])
        #expect(store.isLoading == false)
    }

    @Test func reconnectWithoutCacheDoesNotFetch() async {
        let fake = FakeConnectionManager()
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        fake.responseMap["repo.list"] = ["repos": []]
        fake.responseMap["github.repos.list"] = ["repos": []]
        let store = GitHubRepoStore(connectionManager: fake)

        fake.simulateConnect()
        await drainMainQueue()

        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)
    }
}
