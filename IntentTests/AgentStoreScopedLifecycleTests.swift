import Foundation
@testable import Intent
import Testing

/// Holds one response even if its caller is cancelled, to exercise stores'
/// own freshness guards independently of transport cancellation behavior.
@MainActor
private final class HeldAgentListConnection: FakeConnectionManager {
    var holdNext = false
    var held = false
    let gate = TestGate()

    override func request(
        _ method: String, params: [String: Any] = [:], timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        let shouldHold = holdNext
        holdNext = false
        let result = try await super.request(method, params: params, timeout: timeout)
        if shouldHold {
            held = true
            await gate.wait()
        }
        return result
    }
}

extension AgentStoreTests {
    @Test func olderInitialResponseCannotOverwriteNewerSameWorkspaceRead() async throws {
        let fake = HeldAgentListConnection()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.holdNext = true
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("old")])
        let old = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await waitUntil("held initial response") { fake.held }
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("new")])
        await store.fetchAgents(workspaceId: "ws-1")
        fake.gate.open()
        await old.value
        #expect(store.agents.map(\.id) == ["new"])
        #expect(store.hasLoaded)
        #expect(!store.isLoading)
    }

    @Test func returnedToSameWorkspaceRejectsOldEpochResponse() async throws {
        let fake = HeldAgentListConnection()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.holdNext = true
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("old")])
        let old = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await waitUntil("held old workspace epoch") { fake.held }
        store.prepareForWorkspaceChange(to: "ws-2")
        store.prepareForWorkspaceChange(to: "ws-1")
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("new")])
        await store.fetchAgents(workspaceId: "ws-1")
        fake.gate.open()
        await old.value
        #expect(store.agents.map(\.id) == ["new"])
    }

    @Test func cancelledLazyReadDoesNotPublishAndCanRetry() async throws {
        let (fake, store) = await scopedStore()
        fake.pendingMethods.insert("agent.list")
        let load = Task { await store.loadAgentGroup(.background, workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        load.cancel()
        fake.resolvePending("agent.list", with: scopedResponse([scopedRow("cancelled", background: true)]))
        await load.value
        #expect(store.agents.map(\.id) == ["parent"])
        #expect(store.list.loadingGroups.isEmpty)
        #expect(store.list.loadedGroups.isEmpty)
        fake.pendingMethods.remove("agent.list")
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("retry", background: true)])
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        #expect(store.agents.map(\.id) == ["parent", "retry"])
    }

    @Test func refreshSupersedesOlderLazyReadWithoutLosingItsNewRows() async throws {
        let fake = HeldAgentListConnection()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("parent")])
        await store.fetchAgents(workspaceId: "ws-1")
        fake.holdNext = true
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("old", background: true)])
        let old = Task { await store.loadAgentGroup(.background, workspaceId: "ws-1") }
        try await waitUntil("held lazy read") { fake.held }
        fake.responseQueueMap["agent.list"] = [
            scopedResponse([scopedRow("parent")]), scopedResponse([scopedRow("new", background: true)])
        ]
        await store.fetchAgents(workspaceId: "ws-1")
        fake.gate.open()
        await old.value
        #expect(store.agents.map(\.id) == ["parent", "new"])
        #expect(store.list.loadedGroups.contains(.background))
        #expect(store.list.loadingGroups.isEmpty)
    }

    @Test func lazyReadFinishingBeforeOlderTopLevelReadSurvives() async throws {
        let fake = HeldAgentListConnection()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("parent")])
        await store.fetchAgents(workspaceId: "ws-1")
        fake.holdNext = true
        let refresh = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await waitUntil("held top-level refresh") { fake.held }
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("background", background: true)])
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        fake.gate.open()
        await refresh.value
        #expect(store.agents.map(\.id) == ["parent", "background"])
        #expect(store.list.loadedGroups.contains(.background))
    }

    @Test func lifecycleAndReconnectRefreshOnlyOpenedSections() async throws {
        let (fake, store) = await scopedStore()
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("child", parent: "parent")])
        await store.loadAgentGroup(.delegated(parentId: "parent"), workspaceId: "ws-1")
        store.startObservingEvents()
        for reconnect in [false, true] {
            fake.clearRequestLog()
            fake.responseQueueMap["agent.list"] = [
                scopedResponse([scopedRow("parent")]), scopedResponse([])
            ]
            if reconnect {
                fake.simulateConnect()
            } else {
                fake.deliverEvent(method: "events.event", params: ["type": "agent:retired", "workspaceId": "ws-1"])
            }
            try await fake.waitForRequests("agent.list", count: 2)
            try await waitUntil("requested group refresh completes") { store.list.loadingGroups.isEmpty }
            #expect(store.agents.map(\.id) == ["parent"])
            #expect(fake.paramsForMethod("agent.list").first?["scope"] as? String == "topLevel")
            #expect(fake.paramsForMethod("agent.list").last?["parentAgentId"] as? String == "parent")
            try await expectNever("unopened section request", within: Self.debounceSlack) {
                fake.paramsForMethod("agent.list").count > 2
            }
        }
    }

    @Test func reconnectCapabilityLossUsesWholeBinAndReturnUsesOrphanOnly() async {
        let (fake, store) = await scopedStore()
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("orphan", parent: "missing")])
        await store.loadAgentGroup(.orphaned, workspaceId: "ws-1")
        for orphaned in [false, true] {
            fake.clearRequestLog()
            fake.responseQueueMap["agent.list"] = [
                scopedResponse([scopedRow("parent")], orphaned: orphaned),
                scopedResponse([scopedRow("orphan", parent: "missing")], orphaned: orphaned)
            ]
            await store.fetchAgents(workspaceId: "ws-1")
            let request = fake.paramsForMethod("agent.list").last
            #expect(request?["scope"] as? String == "delegated")
            #expect((request?["orphanedOnly"] as? Bool == true) == orphaned)
            #expect(store.list.orphanedAgentIds == (orphaned ? ["orphan"] : []))
        }
    }

    @Test func retiredRefreshMovesRowsOutOfActiveList() async {
        let (fake, store) = await scopedStore()
        fake.responseMap["agent.list"] = scopedResponse([])
        await store.loadAgentGroup(.retired, workspaceId: "ws-1")
        var retired = scopedRow("parent")
        retired["retiredAt"] = "2026-09-30T00:00:00Z"
        fake.responseQueueMap["agent.list"] = [scopedResponse([]), scopedResponse([retired])]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.agents.isEmpty)
        #expect(store.list.retiredAgents.map(\.id) == ["parent"])
        fake.responseQueueMap["agent.list"] = [scopedResponse([scopedRow("parent")]), scopedResponse([])]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.agents.map(\.id) == ["parent"])
        #expect(store.list.retiredAgents.isEmpty)
    }

    @Test func lazyListRespectsSummaryReadBoundary() async throws {
        let fake = FakeConnectionManager()
        let summaries = AgentSummaryStore()
        let store = AgentStore(connectionManager: fake, summaries: summaries, scopedLoading: true)
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("parent")])
        await store.fetchAgents(workspaceId: "ws-1")
        fake.pendingMethods.insert("agent.list")
        let load = Task { await store.loadAgentGroup(.delegated(parentId: "parent"), workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        summaries.seed([["id": "child", "name": "Fresher detail"]], workspaceId: "ws-1", since: summaries.beginRead())
        fake.resolvePending("agent.list", with: scopedResponse([scopedRow("child", parent: "parent")]))
        await load.value
        #expect(summaries.cached(agentId: "child")["name"] as? String == "Fresher detail")
        #expect(store.agents.map(\.id) == ["parent", "child"])
    }
}

extension AgentStoreTests {
    @Test func scopeCapabilityLossInvalidatesOlderLazyResponse() async throws {
        let fake = HeldAgentListConnection()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("parent")])
        await store.fetchAgents(workspaceId: "ws-1")
        fake.holdNext = true
        fake.responseMap["agent.list"] = scopedResponse([scopedRow("obsolete", background: true)])
        let old = Task { await store.loadAgentGroup(.background, workspaceId: "ws-1") }
        try await waitUntil("held read before capability loss") { fake.held }
        fake.responseMap["agent.list"] = ["agents": [scopedRow("parent"), scopedRow("legacy", background: true)]]
        await store.fetchAgents(workspaceId: "ws-1")
        fake.gate.open()
        await old.value
        #expect(store.list.scopeCounts == nil)
        #expect(store.agents.map(\.id) == ["parent", "legacy"])
        #expect(store.list.loadingGroups.isEmpty)
        #expect(store.isAgentGroupLoaded(.background))
    }

    @Test func malformedGroupResultLeavesSectionRetryable() async {
        let (fake, store) = await scopedStore()
        fake.responseMap["agent.list"] = ["notAgents": []]
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        #expect(!store.isAgentGroupLoaded(.background))
        #expect(store.list.errors[.background] != nil)
        fake.responseMap["agent.list"] = scopedResponse([])
        await store.loadAgentGroup(.background, workspaceId: "ws-1")
        #expect(store.isAgentGroupLoaded(.background))
        #expect(store.list.errors[.background] == nil)
    }
}
