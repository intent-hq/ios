import Foundation
@testable import Intent
import Testing

/// The skill catalog read is one `LoadPhase`: it cannot be loading and failed at once.
@MainActor
struct SkillCatalogLoadPhaseTests {
    private let workspaceId = "skills-\(UUID().uuidString)"

    @Test func movesFromLoadingToLoaded() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["skill.list"]
        let store = SkillCatalogStore()
        let loading = Task { await store.load(workspaceId: workspaceId, agentId: "agent", connection: fake) }
        try await fake.waitForPendingRequests("skill.list")
        #expect(store.loadPhase == .loading(lastLoadedAt: nil))

        fake.resolvePending("skill.list", with: [["name": "review", "description": "d", "location": "/r", "scope": "user"]])
        await loading.value
        #expect(store.loadPhase.hasLoaded && !store.loadPhase.isLoading)
        #expect(store.skills.map(\.name) == ["review"])
    }

    @Test func anEmptyCatalogIsLoadedNotFailed() async {
        let fake = FakeConnectionManager()
        fake.responseMap["skill.list"] = [] as [Any]
        let store = SkillCatalogStore()
        await store.load(workspaceId: workspaceId, agentId: "agent", connection: fake)
        #expect(store.loadPhase.hasLoaded && store.skills.isEmpty && store.errorMessage == nil)
    }

    @Test func aFailedLoadIsFailedAndRetryShowsLoadingWithoutTheError() async throws {
        let fake = FakeConnectionManager()
        fake.errorMap["skill.list"] = URLError(.timedOut)
        let store = SkillCatalogStore()
        await store.load(workspaceId: workspaceId, agentId: "agent", connection: fake)
        #expect(store.loadPhase == .failed("Skills could not be loaded. Try again."))
        #expect(!store.isLoading)

        fake.errorMap.removeValue(forKey: "skill.list")
        fake.pendingMethods = ["skill.list"]
        let retry = Task { await store.load(workspaceId: workspaceId, agentId: "agent", connection: fake) }
        try await fake.waitForPendingRequests("skill.list")
        #expect(store.isLoading && store.errorMessage == nil)
        fake.resolvePending("skill.list", with: [] as [Any])
        await retry.value
        #expect(store.loadPhase.hasLoaded)
    }

    /// Skills do not change in a session, so a loaded catalog is served from
    /// the cache instead of being refreshed: an outage cannot replace it.
    @Test func aLoadedCatalogSurvivesALaterOutage() async {
        let fake = FakeConnectionManager()
        fake.responseMap["skill.list"] = [["name": "kept", "description": "d", "location": "/k", "scope": "user"]]
        let store = SkillCatalogStore()
        await store.load(workspaceId: workspaceId, agentId: "agent", connection: fake)
        fake.errorMap["skill.list"] = URLError(.notConnectedToInternet)
        await store.load(workspaceId: workspaceId, agentId: "agent", connection: fake)
        #expect(store.skills.map(\.name) == ["kept"])
        #expect(store.loadPhase.hasLoaded && store.errorMessage == nil)
        #expect(fake.paramsForMethod("skill.list").count == 1)
    }

    @Test func resetReturnsToIdle() async {
        let fake = FakeConnectionManager()
        fake.errorMap["skill.list"] = URLError(.timedOut)
        let store = SkillCatalogStore()
        await store.load(workspaceId: workspaceId, agentId: "agent", connection: fake)
        store.reset()
        #expect(store.loadPhase == .idle)
    }
}
