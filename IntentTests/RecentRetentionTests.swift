@testable import Intent
import Testing

@MainActor
struct RecentRetentionTests {
    @Test func keepsOnlyTheMostRecentlyTouchedValues() {
        var retention = RecentRetention<String, Int>(capacity: 3)
        for (index, key) in ["a", "b", "c", "d"].enumerated() { retention.touch(key, value: index) }
        #expect(retention.value(for: "a") == nil, "Oldest key is dropped first")
        #expect(retention.keys == ["b", "c", "d"])
    }

    @Test func touchingAnExistingKeyRenewsIt() {
        var retention = RecentRetention<String, Int>(capacity: 2)
        retention.touch("a", value: 1)
        retention.touch("b", value: 2)
        retention.touch("a", value: 1)
        retention.touch("c", value: 3)
        #expect(retention.value(for: "a") == 1)
        #expect(retention.value(for: "b") == nil)
    }

    @Test func removeAllForgetsEverything() {
        var retention = RecentRetention<String, Int>(capacity: 2)
        retention.touch("a", value: 1)
        retention.removeAll()
        #expect(retention.keys.isEmpty)
    }

    @Test func conversationPoolRetainsTenMostRecentConversations() {
        let connection = FakeConnectionManager()
        let pool = ConversationStorePool(connection: connection, details: AgentDetailStore(connection: connection))
        weak var oldest: ConversationStore?
        weak var tenth: ConversationStore?
        for index in 0...ConversationStorePool.retainedConversationLimit {
            let store = pool.store(agentId: "agent-\(index)")
            if index == 0 { oldest = store }
            if index == 1 { tenth = store }
        }
        #expect(oldest == nil, "The 11th most recent conversation is released")
        #expect(tenth != nil, "The 10th most recent conversation stays readable")
        pool.reset()
        #expect(tenth == nil, "Back to Home, switching Mac and Log Off drop retained conversations")
    }

    @Test func workspaceDetailCacheRetainsFiveMostRecentWorkspaces() {
        let connection = FakeConnectionManager()
        let summaries = AgentDetailStore(connection: connection).summaries
        let cache = WorkspaceDetailStoresCache()
        let make = { WorkspaceDetailStores(connection: connection, summaries: summaries) }
        let first = cache.stores(for: "workspace-0", make: make)
        for index in 1..<WorkspaceDetailStoresCache.retainedWorkspaceLimit {
            _ = cache.stores(for: "workspace-\(index)", make: make)
        }
        #expect(cache.stores(for: "workspace-0", make: make) === first, "The 5th most recent workspace keeps its stores")
        for index in 1...WorkspaceDetailStoresCache.retainedWorkspaceLimit {
            _ = cache.stores(for: "workspace-new-\(index)", make: make)
        }
        #expect(cache.stores(for: "workspace-0", make: make) !== first, "The 6th most recent workspace is dropped")
        let current = cache.stores(for: "workspace-0", make: make)
        cache.removeAll()
        #expect(cache.stores(for: "workspace-0", make: make) !== current)
    }

    @Test @MainActor func leavingTheRemoteUIDropsRetainedWorkspaces() {
        let connection = FakeConnectionManager()
        let coordinator = AppCoordinator(workspaceStore: WorkspaceStore(forTesting: true), connection: connection)
        let summaries = AgentDetailStore(connection: connection).summaries
        let make = { WorkspaceDetailStores(connection: connection, summaries: summaries) }
        let stores = coordinator.workspaceDetailStores.stores(for: "workspace", make: make)
        coordinator.currentScreen = .pairing
        #expect(coordinator.workspaceDetailStores.stores(for: "workspace", make: make) !== stores)
    }
}
