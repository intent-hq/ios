import Foundation
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

    @Test func releasingLastWorkspaceLeaseSuspendsSubscriptionsWhileRetainingRows() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.list"] = ["agents": [["id": "a-1", "name": "Agent 1"]]]
        fake.responseMap["note.list"] = ["notes": [["id": "n-1", "title": "Note 1", "content": "", "createdAt": "", "updatedAt": ""]]]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "note-sub-1"]
        fake.responseMap["note.unsubscribe"] = ["ok": true]
        fake.responseMap["events.subscribe"] = ["subscriptionId": "script-sub-1"]
        fake.responseMap["events.unsubscribe"] = ["ok": true]
        fake.responseMap["script.list"] = ["scripts": [["id": "s-1", "workspaceId": "ws-1", "name": "dev", "command": "npm run dev"]]]
        let summaries = AgentDetailStore(connection: fake).summaries
        let baselineHandlers = fake.eventHandlerCount
        let stores = WorkspaceDetailStores(connection: fake, summaries: summaries)

        let firstLease = UUID()
        let secondLease = UUID()
        stores.retain(firstLease, workspaceId: "ws-1")
        stores.retain(secondLease, workspaceId: "ws-1")
        fake.simulateConnect()
        await stores.agentStore.fetchAgents(workspaceId: "ws-1")
        await stores.noteStore.fetchNotes(workspaceId: "ws-1")
        await stores.scriptStore.refresh(workspaceId: "ws-1")
        try await waitUntil("note subscription registered") { fake.hasSubscriptionHandler(id: "note-sub-1") }

        // Releasing one of two overlapping leases (e.g. iPad detail -> sidebar handoff) keeps observation live.
        stores.release(firstLease)
        #expect(fake.eventHandlerCount > baselineHandlers)
        #expect(fake.hasSubscriptionHandler(id: "note-sub-1"))

        // Releasing the final lease detaches offscreen handlers/subscriptions while keeping cached rows.
        fake.clearRequestLog()
        stores.release(secondLease)
        try await waitUntil("unsubscribes sent") {
            fake.didCallMethod("note.unsubscribe") && fake.didCallMethod("events.unsubscribe")
        }
        #expect(fake.eventHandlerCount == baselineHandlers)
        #expect(!fake.hasSubscriptionHandler(id: "note-sub-1"))
        #expect(stores.agentStore.agents.map(\.id) == ["a-1"])
        #expect(stores.noteStore.notes.map(\.id) == ["n-1"])
        #expect(stores.scriptStore.scripts(workspaceId: "ws-1").map(\.id) == ["s-1"])

        // Offscreen events and reconnects must not trigger background RPC refetches.
        fake.clearRequestLog()
        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "agent:updated", "workspaceId": "ws-1", "data": ["agentId": "a-1"]]
        ])
        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:updated", "workspaceId": "ws-1", "noteId": "n-1"]
        ])
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await expectNever("background RPCs for offscreen cached workspace", within: .milliseconds(250)) {
            fake.didCallMethod("agent.list") || fake.didCallMethod("note.list") || fake.didCallMethod("script.list")
        }

        // Re-retaining on return restores observation cleanly.
        fake.responseMap["note.subscribe"] = ["subscriptionId": "note-sub-2"]
        stores.retain(UUID(), workspaceId: "ws-1")
        try await waitUntil("note subscription restored on return") { fake.hasSubscriptionHandler(id: "note-sub-2") }
        #expect(fake.eventHandlerCount > baselineHandlers)
    }
}
