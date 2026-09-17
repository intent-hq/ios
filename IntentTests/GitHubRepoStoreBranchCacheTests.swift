import Foundation
@testable import Intent
import Testing

extension GitHubRepoStoreTests {
    // MARK: - fetchCachedBranches (github.branches.listCached)

    @Test func fetchCachedBranchesReadsListCached() async {
        let fake = FakeConnectionManager()
        let store = GitHubRepoStore(connectionManager: fake)
        fake.responseMap["github.branches.listCached"] = [
            "cached": true, "source": "cache",
            "branches": ["dev", "main"], "defaultBranch": "main"
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
            "cached": false, "source": "ls-remote", "branches": ["main"]
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
            domain: "WebSocket",
            code: -32_601,
            userInfo: [NSLocalizedDescriptionKey: "Method not found"]
        )
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
            domain: "t",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )

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
            domain: "t",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )
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

        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult == secondResult)
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
        #expect(
            store.branchState(owner: "o", repo: "r")
                == GitHubBranchLoadState(
                    listing: GitHubBranchListing(branches: ["main"], defaultBranch: "main")
                )
        )
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
            domain: "WebSocket",
            code: -32_603,
            userInfo: [NSLocalizedDescriptionKey: "repo cache warm already in flight for o/r"]
        )

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
