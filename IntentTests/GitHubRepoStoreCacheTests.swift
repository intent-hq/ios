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
        fake.pendingMethods = ["github.repos.list"]

        await store.loadIfNeeded()

        try await waitFor {
            fake.paramsForMethod("github.repos.list").count == 2
                && fake.paramsForMethod("repo.list").count == 2
        }
        #expect(store.isLoading == false)
        #expect(store.hasLoaded)
        #expect(store.recentRepos == cachedRecents)
        #expect(store.ownRepos == cachedOwn)
        #expect(fake.paramsForMethod("github.authStatus").count == 2)

        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "fresh")]])
        try await waitFor { store.ownRepos.map(\.name) == ["fresh"] }
        #expect(store.isLoading == false)
    }

    @Test func concurrentColdLoadsShareOneFlight() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["repo.list"] = ["repos": []]
        fake.responseMap["github.repos.list"] = ["repos": [makeRepoDict()]]
        fake.pendingMethods = ["github.authStatus"]
        let store = GitHubRepoStore(connectionManager: fake)

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

        #expect(store.hasCheckedAuth == false)
        #expect(store.isConfigured == false)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.lastError == "socket closed")
        #expect(store.isLoading == false)
        #expect(fake.didCallMethod("github.repos.list") == false)

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

        #expect(store.isConfigured == true)
        #expect(store.hasCheckedAuth)
        #expect(store.hasLoaded)
        #expect(store.recentRepos == cachedRecents)
        #expect(store.ownRepos == cachedOwn)
        #expect(store.lastError == "socket closed")
        #expect(store.isLoading == false)
        #expect(fake.didCallMethod("github.repos.list") == false)

        fake.clearRequestLog()
        let forcedLoad = store.latestLoadTask
        await store.loadIfNeeded()
        let refresh = try #require(store.latestLoadTask)
        #expect(refresh != forcedLoad)
        await refresh.value
        #expect(fake.didCallMethod("github.authStatus"))
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
        fake.pendingMethods = ["github.repos.list"]
        await store.loadIfNeeded()
        try await waitFor("refresh read") { fake.paramsForMethod("github.repos.list").count == 2 }
        let staleLoad = try #require(store.latestLoadTask)

        store.invalidate()
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)

        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "stale")]])
        await staleLoad.value
        #expect(store.ownRepos.isEmpty)
        #expect(store.recentRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.lastLoadedAt == nil)
        #expect(store.isLoading == false)

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
        let previousLoad = store.latestLoadTask
        await store.loadIfNeeded()
        let refresh = try #require(store.latestLoadTask)
        #expect(refresh != previousLoad)
        store.invalidate()

        await refresh.value
        #expect(fake.requestLog.isEmpty)
        #expect(store.isLoading == false)
        #expect(store.hasLoaded == false)
        #expect(store.hasCheckedAuth == false)
        #expect(store.ownRepos.isEmpty)
        #expect(store.recentRepos.isEmpty)

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
        #expect(store.recentRepos.map(\.fullName) == ["intent-hq/monorepo"])
        #expect(store.hasLoaded == false)
        #expect(store.lastError != nil)

        fake.errorMap["github.authStatus"] = nil
        fake.responseMap["github.authStatus"] = ["isConfigured": true]
        fake.pendingMethods = ["github.authStatus", "repo.list"]
        fake.clearRequestLog()

        fake.simulateConnect()

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
        fake.pendingMethods = ["github.authStatus", "repo.list"]
        fake.clearRequestLog()

        fake.simulateConnect()

        try await waitFor("reload reads") {
            fake.didCallMethod("github.authStatus") && fake.didCallMethod("repo.list")
        }
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
        fake.pendingMethods = ["github.repos.list"]
        await store.loadIfNeeded()
        try await waitFor("pre-reconnect read") { fake.paramsForMethod("github.repos.list").count == 2 }
        let staleLoad = try #require(store.latestLoadTask)

        fake.simulateConnect()

        try await waitFor("reconnect read") { fake.paramsForMethod("github.repos.list").count == 3 }
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

        fake.resolvePending("github.repos.list", with: ["repos": [makeRepoDict(name: "stale")]])
        await staleLoad.value
        #expect(store.ownRepos.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.isLoading)

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
        try await waitFor("reconnect handler") { store.latestConnectionTask != nil }
        await store.latestConnectionTask?.value

        #expect(fake.requestLog.isEmpty)
        #expect(store.hasLoaded == false)
    }
}
