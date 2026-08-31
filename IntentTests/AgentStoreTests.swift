import Foundation
import Testing
import Combine
@testable import Intent

@MainActor
struct AgentStoreTests {

    // MARK: - hasLoaded gating (empty state waits for first completed load)

    @Test func hasLoadedFalseUntilFirstFetchSucceeds() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        #expect(store.hasLoaded == false)

        fake.pendingMethods.insert("agent.list")
        let fetch = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Fetch in flight: still not loaded
        #expect(store.hasLoaded == false)
        #expect(store.isLoading == true)

        fake.resolvePending("agent.list", with: ["agents": [
            ["id": "agent-1", "name": "Agent 1"]
        ]])
        await fetch.value
        #expect(store.hasLoaded == true)
        #expect(store.isLoading == false)
        #expect(store.agents.count == 1)
    }

    @Test func failedFetchLeavesHasLoadedFalse() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        // ConnectionManager.request throws immediately while the socket is
        // still connecting ("Not connected") — must not flip to empty state.
        fake.errorMap["agent.list"] = NSError(
            domain: "WebSocket", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"])

        await store.fetchAgents(workspaceId: "ws-1")

        #expect(store.hasLoaded == false)
        #expect(store.isLoading == false)
    }

    @Test func emptySuccessfulResultSetsHasLoaded() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = ["agents": []]

        await store.fetchAgents(workspaceId: "ws-1")

        // Legitimate empty workspace: empty state may render now
        #expect(store.hasLoaded == true)
        #expect(store.agents.isEmpty)
    }

    @Test func workspaceChangeResetsHasLoaded() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = ["agents": [
            ["id": "agent-1", "name": "Agent 1"]
        ]]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)

        // Switching workspaces resets the gate; the failed fetch for the new
        // workspace keeps it false.
        fake.responseMap.removeValue(forKey: "agent.list")
        fake.errorMap["agent.list"] = NSError(
            domain: "WebSocket", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        await store.fetchAgents(workspaceId: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.agents.isEmpty)
    }

    @Test func staleFetchForPreviousWorkspaceDoesNotFlipHasLoaded() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.pendingMethods.insert("agent.list")

        let staleFetch = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let currentFetch = Task { await store.fetchAgents(workspaceId: "ws-2") }
        try await Task.sleep(nanoseconds: 50_000_000)

        // The stale ws-1 fetch completing must not mark ws-2 as loaded.
        fake.resolvePending("agent.list", with: ["agents": [
            ["id": "agent-old", "name": "Old"]
        ]])
        await staleFetch.value
        #expect(store.hasLoaded == false)

        fake.resolvePending("agent.list", with: ["agents": []])
        await currentFetch.value
        #expect(store.hasLoaded == true)
    }

    @Test func prepareForWorkspaceChangeResetsSynchronously() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = ["agents": [
            ["id": "agent-1", "name": "Agent 1"]
        ]]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)

        // Same workspace: no-op (re-appear must not flash the loading state)
        store.prepareForWorkspaceChange(to: "ws-1")
        #expect(store.hasLoaded == true)
        #expect(store.agents.count == 1)

        // Different workspace: resets synchronously, before any fetch runs
        store.prepareForWorkspaceChange(to: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.agents.isEmpty)
    }

    // MARK: - Refetch on connect (mirrors NoteStore.onConnected)

    @Test func refetchesOnConnectWithWorkspaceContext() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        // Initial fetch fails while the socket is still connecting.
        fake.errorMap["agent.list"] = NSError(
            domain: "WebSocket", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.hasLoaded == false)

        // Connection comes up: the store must retry on its own, not wait
        // for a coincidental agent event.
        fake.errorMap.removeValue(forKey: "agent.list")
        fake.responseMap["agent.list"] = ["agents": [
            ["id": "agent-1", "name": "Agent 1"]
        ]]
        fake.clearRequestLog()
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(fake.didCallMethod("agent.list"))
        #expect(store.hasLoaded == true)
        #expect(store.agents.count == 1)
    }

    @Test func connectWithoutWorkspaceContextDoesNotFetch() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = ["agents": []]

        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!fake.didCallMethod("agent.list"))
        #expect(store.hasLoaded == false)
    }
}
