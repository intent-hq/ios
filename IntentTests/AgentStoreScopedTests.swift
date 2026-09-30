import Foundation
@testable import Intent
import Testing

extension AgentStoreTests {
    func scopedResponse(_ rows: [[String: Any]], orphaned: Bool = true) -> [String: Any] {
        var delegated: [String: Any] = ["running": 1, "byParent": ["parent": ["total": 2, "running": 1]]]
        if orphaned { delegated["orphaned"] = ["total": 1, "running": 0] }
        return [
            "agents": rows, "retiredCount": 1,
            "scopeCounts": ["topLevel": 1, "delegated": 2, "background": 1],
            "delegatedCounts": delegated
        ]
    }

    func scopedRow(_ id: String, parent: String? = nil, background: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["id": id, "name": id, "metadata": ["isBackground": background]]
        if let parent { row["parentAgentId"] = parent }
        return row
    }

    func scopedStore() async -> (FakeConnectionManager, AgentStore) {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("parent")])
        await store.fetchAgents(workspaceId: "ws-1")
        return (fake, store)
    }

    @Test func scopedInitialReadOnlyRequestsTopLevelAndDecodesCounts() async {
        let (fake, store) = await scopedStore()
        let requests = fake.paramsForMethod("agent.list")
        #expect(requests.count == 1)
        #expect(requests.first?["scope"] as? String == "topLevel")
        #expect(requests.first?["workspaceId"] as? String == "ws-1")
        #expect(store.list.retiredCount == 1)
        #expect(store.list.scopeCounts?.background == 1)
        #expect(store.list.delegatedCounts?.byParent["parent"]?.total == 2)
        #expect(store.list.delegatedCounts?.orphaned?.total == 1)
        #expect(store.list.loadedGroups.isEmpty)
    }

    @Test func scopedLazyReadsUseCorrectParametersAndKeepOtherGroups() async {
        let (fake, store) = await scopedStore()
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("child", parent: "parent", background: true)])
        await store.loadAgentGroup(.delegated(parentId: "parent"), workspaceId: "ws-1")
        var request = fake.paramsForMethod("agent.list").last
        #expect(request?["scope"] as? String == "delegated")
        #expect(request?["parentAgentId"] as? String == "parent")
        #expect(request?["orphanedOnly"] == nil)

        fake.responseMap["agent.list"] = scopedResponse([scopedRow("background", background: true)])
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        request = fake.paramsForMethod("agent.list").last
        #expect(request?["scope"] as? String == "background")

        fake.responseMap["agent.list"] = scopedResponse([scopedRow("orphan", parent: "missing")])
        await store.loadAgentGroup(.orphaned, workspaceId: "ws-1")
        request = fake.paramsForMethod("agent.list").last
        #expect(request?["scope"] as? String == "delegated")
        #expect(request?["orphanedOnly"] as? Bool == true)
        #expect(request?["parentAgentId"] == nil)
        #expect(store.list.orphanedAgentIds == ["orphan"])

        var retired = scopedRow("retired")
        retired["retiredAt"] = "2026-09-30T00:00:00Z"
        fake.responseMap["agent.list"] = scopedResponse([retired])
        await store.loadAgentGroup(.retired, workspaceId: "ws-1")
        request = fake.paramsForMethod("agent.list").last
        #expect(request?["retiredOnly"] as? Bool == true)
        #expect(request?["scope"] == nil)
        #expect(Set(store.agents.map(\.id)) == ["parent", "child", "background", "orphan"])
        #expect(store.list.retiredAgents.map(\.id) == ["retired"])
    }

    @Test func missingScopeMetadataKeepsLegacyRowsWithoutExtraReads() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = ["agents": [scopedRow("parent"), scopedRow("child", parent: "parent")]]
        await store.fetchAgents(workspaceId: "ws-1")
        await store.loadAgentGroup(.delegated(parentId: "parent"), workspaceId: "ws-1")
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        await store.loadAgentGroup(.orphaned, workspaceId: "ws-1")
        #expect(fake.paramsForMethod("agent.list").count == 1)
        #expect(store.agents.map(\.id) == ["parent", "child"])
        #expect(store.list.scopeCounts == nil)
    }

    @Test func missingOrphanMetadataFallsBackToWholeDelegatedScope() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("parent")], orphaned: false)
        await store.fetchAgents(workspaceId: "ws-1")
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("child", parent: "parent")], orphaned: false)
        await store.loadAgentGroup(.orphaned, workspaceId: "ws-1")
        let request = fake.paramsForMethod("agent.list").last
        #expect(request?["scope"] as? String == "delegated")
        #expect(request?["orphanedOnly"] == nil)
        #expect(store.list.orphanedAgentIds.isEmpty)
        #expect(store.agents.map(\.id) == ["parent", "child"])
    }

    @Test func defaultStorePreservesAllActiveConsumerRequest() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        var delegated = scopedRow("child", parent: "parent")
        delegated["name"] = "Delegated assignee"
        delegated["createdAt"] = "2026-09-30T00:00:00Z"
        fake.responseMap["agent.list"] = scopedResponse([delegated])
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("agent.list").first?["scope"] == nil)
        #expect(store.agents.map(\.id) == ["child"])
        #expect(store.agents.first?.name == "Delegated assignee")
        #expect(store.agents.first?.createdAt == "2026-09-30T00:00:00Z")
    }

    @Test func duplicateExpansionIsDeduplicatedAndFailedLoadRetries() async throws {
        let (fake, store) = await scopedStore()
        fake.pendingMethods.insert("agent.list")
        let load = Task { await store.loadAgentGroup(.background, workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        #expect(fake.pendingRequestCount("agent.list") == 1)
        fake.failPending("agent.list", with: NSError(domain: "test", code: 1))
        await load.value
        #expect(!store.list.loadedGroups.contains(.background))
        #expect(store.list.loadingGroups.isEmpty)
        #expect(store.list.errors[.background] != nil)
        fake.pendingMethods.remove("agent.list")
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("background", background: true)])
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        #expect(store.list.loadedGroups.contains(.background))
        #expect(store.list.errors[.background] == nil)
        let count = fake.requestLog.count
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        #expect(fake.requestLog.count == count)
    }

    @Test func scopedRefreshReplacesOnlyRequestedGroups() async {
        let (fake, store) = await scopedStore()
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("old", parent: "parent")])
        await store.loadAgentGroup(.delegated(parentId: "parent"), workspaceId: "ws-1")
        fake.clearRequestLog()
        fake.responseQueueMap["agent.list"] = [
            scopedResponse([scopedRow("parent")]), scopedResponse([scopedRow("new", parent: "parent")])
        ]
        await store.fetchAgents(workspaceId: "ws-1")
        let requests = fake.paramsForMethod("agent.list")
        #expect(requests.count == 2)
        #expect(requests.first?["scope"] as? String == "topLevel")
        #expect(requests.last?["parentAgentId"] as? String == "parent")
        #expect(store.agents.map(\.id) == ["parent", "new"])
    }

    @Test func lazyResponseFromPreviousWorkspaceCannotPublishOrClearNewLoading() async throws {
        let (fake, store) = await scopedStore()
        fake.pendingMethods.insert("agent.list")
        let old = Task { await store.loadAgentGroup(.background, workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        store.prepareForWorkspaceChange(to: "ws-2")
        let current = Task { await store.fetchAgents(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("agent.list", count: 2)
        fake.resolvePending("agent.list", with: scopedResponse([scopedRow("old", background: true)]))
        await old.value
        #expect(store.agents.isEmpty)
        #expect(store.isLoading)
        #expect(store.list.loadedGroups.isEmpty)
        fake.resolvePending("agent.list", with: scopedResponse([scopedRow("new")]))
        await current.value
        #expect(store.agents.map(\.id) == ["new"])
    }

    @Test func lazyLoadFinishingDuringTopLevelRefreshSurvives() async throws {
        let (fake, store) = await scopedStore()
        fake.pendingMethods.insert("agent.list")
        let refresh = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        let load = Task { await store.loadAgentGroup(.background, workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list", count: 2)
        fake.resolvePending("agent.list", with: scopedResponse([scopedRow("parent")]))
        fake.resolvePending("agent.list", with: scopedResponse([scopedRow("background", background: true)]))
        await refresh.value
        await load.value
        #expect(Set(store.agents.map(\.id)) == ["parent", "background"])
    }
}
