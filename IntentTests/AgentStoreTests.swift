import Combine
import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

@MainActor
struct AgentStoreTests {
    /// Margin added to `fetchDebounce` when holding that no further
    /// `agent.list` request is issued after the debounce window.
    static let debounceSlack: Duration = .milliseconds(200)

    // MARK: - hasLoaded gating (empty state waits for first completed load)

    @Test func hasLoadedFalseUntilFirstFetchSucceeds() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        #expect(store.hasLoaded == false)

        fake.pendingMethods.insert("agent.list")
        let fetch = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        // Fetch in flight: still not loaded
        #expect(store.hasLoaded == false)
        #expect(store.isLoading == true)

        fake.resolvePending("agent.list", with: [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"]
            ]
        ])
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
            domain: "WebSocket",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"]
        )

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
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"]
            ]
        ]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)

        // Switching workspaces resets the gate; the failed fetch for the new
        // workspace keeps it false.
        fake.responseMap.removeValue(forKey: "agent.list")
        fake.errorMap["agent.list"] = NSError(
            domain: "WebSocket",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"]
        )
        await store.fetchAgents(workspaceId: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.agents.isEmpty)
    }

    @Test func staleFetchForPreviousWorkspaceDoesNotFlipHasLoaded() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.pendingMethods.insert("agent.list")

        let staleFetch = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        let currentFetch = Task { await store.fetchAgents(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("agent.list", count: 2)

        // The stale ws-1 fetch completing must not mark ws-2 as loaded
        // nor replace ws-2's agents with ws-1's.
        fake.resolvePending("agent.list", with: [
            "agents": [
                ["id": "agent-old", "name": "Old"]
            ]
        ])
        await staleFetch.value
        #expect(store.hasLoaded == false)
        #expect(store.agents.isEmpty)

        fake.resolvePending("agent.list", with: ["agents": []])
        await currentFetch.value
        #expect(store.hasLoaded == true)
    }

    @Test func staleResponseAfterPrepareForWorkspaceChangeIsIgnored() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.pendingMethods.insert("agent.list")

        let staleFetch = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")

        // The view switched workspaces; its async fetch for ws-2 has not
        // started yet. The old ws-1 response landing in this window must not
        // supply agents nor flip hasLoaded for ws-2.
        store.prepareForWorkspaceChange(to: "ws-2")
        fake.resolvePending("agent.list", with: [
            "agents": [
                ["id": "agent-old", "name": "Old"]
            ]
        ])
        await staleFetch.value

        #expect(store.hasLoaded == false)
        #expect(store.agents.isEmpty)
    }

    @Test func prepareForWorkspaceChangeResetsSynchronously() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"]
            ]
        ]
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

    // MARK: - Identical refetch stays quiet (no re-render underneath swipe-back)

    @Test func identicalRefetchDoesNotReassignAgents() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"]
            ]
        ]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)
        #expect(store.agents.count == 1)

        // The deferred refresh after re-appearing for the same workspace
        // returns the same list: no observed property may be invalidated,
        // or the agent list rebuilds during the pop transition.
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.agents
            _ = store.hasLoaded
            _ = store.isLoading
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("agent.list").count == 2)
        #expect(changeCount.withLock { $0 } == 0)
        #expect(store.agents.count == 1)

        // A genuinely different list must still publish.
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"],
                ["id": "agent-2", "name": "Agent 2"]
            ]
        ]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(changeCount.withLock { $0 } == 1)
        #expect(store.agents.map(\.id) == ["agent-1", "agent-2"])
    }

    // MARK: - Cancelled refetch (view disappeared under the deferred refresh)

    /// Loads one agent so subsequent fetches take the debounced path.
    private func makeLoadedStore() async -> (FakeConnectionManager, AgentStore) {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"]
            ]
        ]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.agents.map(\.id) == ["agent-1"])
        #expect(fake.paramsForMethod("agent.list").count == 1)
        return (fake, store)
    }

    @Test func cancellingRefetchDuringDebounceIssuesNoRequest() async throws {
        let (fake, store) = await makeLoadedStore()

        // Cancel the caller while the debounce sleep is still pending: the
        // unstructured debounce task must be cancelled with it, so no
        // agent.list request is issued once the window would have elapsed.
        // The 50 ms positions the caller inside the 300 ms debounce window;
        // nothing observable marks that window, and either ordering must
        // still issue no request.
        let refresh = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await Task.sleep(for: .milliseconds(50))
        refresh.cancel()
        await refresh.value
        try await expectNever(
            "agent.list request after the cancelled debounce",
            within: Constants.AgentStore.fetchDebounce + Self.debounceSlack
        ) {
            fake.paramsForMethod("agent.list").count > 1
        }

        #expect(store.agents.map(\.id) == ["agent-1"])
    }

    @Test func cancellingRefetchWithRequestInFlightDoesNotPublish() async throws {
        let (fake, store) = await makeLoadedStore()

        // Let the debounce elapse and the request go out, then cancel while
        // the response is still pending: a late response must not publish.
        fake.pendingMethods.insert("agent.list")
        let refresh = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        #expect(fake.paramsForMethod("agent.list").count == 2)

        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.agents
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }
        // Cancel and resolve back-to-back on the main actor: the fake's
        // cancellation hop is asynchronous, so the request resumes with the
        // real (changed) payload inside an already-cancelled task.
        refresh.cancel()
        fake.resolvePending("agent.list", with: [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"],
                ["id": "agent-2", "name": "Agent 2"]
            ]
        ])
        await refresh.value

        #expect(changeCount.withLock { $0 } == 0)
        #expect(store.agents.map(\.id) == ["agent-1"])
        #expect(store.isLoading == false)

        // The store is not poisoned: a later, uncancelled fetch publishes.
        fake.pendingMethods.remove("agent.list")
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"],
                ["id": "agent-2", "name": "Agent 2"]
            ]
        ]
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.agents.map(\.id) == ["agent-1", "agent-2"])
    }

    @Test func cancellingSupersededRefetchLeavesNewerFetchRunning() async throws {
        let (fake, store) = await makeLoadedStore()
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"],
                ["id": "agent-2", "name": "Agent 2"]
            ]
        ]

        // A newer fetch supersedes the first one's debounce task. Cancelling
        // the first caller afterwards must only cancel its own (already
        // replaced) task, never the newer fetch. The 50 ms sleeps position
        // each caller inside the 300 ms debounce window; nothing observable
        // marks that window.
        let first = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        await first.value
        await second.value

        #expect(fake.paramsForMethod("agent.list").count == 2)
        #expect(store.agents.map(\.id) == ["agent-1", "agent-2"])
    }

    // MARK: - Refetch on connect (mirrors NoteStore.onConnected)

    @Test func refetchesOnConnectWithWorkspaceContext() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        // Initial fetch fails while the socket is still connecting.
        fake.errorMap["agent.list"] = NSError(
            domain: "WebSocket",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"]
        )
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.hasLoaded == false)

        // Connection comes up: the store must retry on its own, not wait
        // for a coincidental agent event.
        fake.errorMap.removeValue(forKey: "agent.list")
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-1", "name": "Agent 1"]
            ]
        ]
        fake.clearRequestLog()
        fake.simulateConnect()
        try await waitUntil("agent.list refetch on connect") { store.hasLoaded }

        #expect(fake.didCallMethod("agent.list"))
        #expect(store.agents.count == 1)
    }

    @Test func connectWithoutWorkspaceContextDoesNotFetch() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = ["agents": []]

        fake.simulateConnect()
        try await expectNever(
            "agent.list request on connect without workspace context",
            within: .milliseconds(200)
        ) {
            fake.didCallMethod("agent.list")
        }

        #expect(store.hasLoaded == false)
    }

    // MARK: - Notification mute round-trip (agent.update)

    @Test func setNotificationsMutedSendsUpdateAndAppliesResultRow() async throws {
        let (fake, store) = await makeLoadedStore()
        #expect(store.agents.first?.notificationsMuted == false)
        fake.responseMap["agent.update"] = [
            "success": true,
            "agent": ["id": "agent-1", "name": "Agent 1", "notificationsMuted": true] as [String: Any]
        ]

        try await store.setNotificationsMuted(agentId: "agent-1", workspaceId: "ws-1", muted: true)

        let params = fake.paramsForMethod("agent.update")
        #expect(params.count == 1)
        #expect(params.first?["agentId"] as? String == "agent-1")
        #expect(params.first?["workspaceId"] as? String == "ws-1")
        let changes = params.first?["changes"] as? [String: Any]
        #expect(changes?.count == 1)
        #expect(changes?["notificationsMuted"] as? Bool == true)
        #expect(store.agents.map(\.id) == ["agent-1"])
        #expect(store.agents.first?.notificationsMuted == true)
    }

    @Test func setNotificationsMutedFailurePropagatesAndLeavesRowUntouched() async {
        let (fake, store) = await makeLoadedStore()
        fake.errorMap["agent.update"] = NSError(
            domain: "JSONRPC",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "agent.update: `notificationsMuted` must be a boolean"]
        )

        await #expect(throws: (any Error).self) {
            try await store.setNotificationsMuted(agentId: "agent-1", workspaceId: "ws-1", muted: true)
        }
        #expect(store.agents.first?.notificationsMuted == false)
    }
}

// MARK: - Event allowlist (streaming firehose must not refetch the list)

extension AgentStoreTests {
    private func deliverAgentEvent(_ fake: FakeConnectionManager, type: String) {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-agents",
            "event": [
                "type": type,
                "workspaceId": "ws-1",
                "data": ["agentId": "agent-1"]
            ]
        ] as [String: Any])
    }

    /// Delivers `type` to a loaded, observing store, waits for the one
    /// debounced `agent.list` refetch it must issue, and holds that no
    /// second one follows across another debounce window.
    private func expectRefetch(
        after type: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let (fake, store) = await makeLoadedStore()
        store.startObservingEvents()
        fake.clearRequestLog()

        deliverAgentEvent(fake, type: type)
        try await fake.waitForRequests("agent.list", sourceLocation: sourceLocation)
        try await expectNever(
            "second agent.list refetch after \(type)",
            within: Constants.AgentStore.fetchDebounce + Self.debounceSlack,
            sourceLocation: sourceLocation
        ) {
            fake.paramsForMethod("agent.list").count > 1
        }
    }

    /// Delivers `type` to a loaded, observing store and holds that no
    /// `agent.list` refetch is issued across the debounce window.
    private func expectNoRefetch(
        after type: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let (fake, store) = await makeLoadedStore()
        store.startObservingEvents()
        fake.clearRequestLog()

        deliverAgentEvent(fake, type: type)
        try await expectNever(
            "agent.list refetch after \(type)",
            within: Constants.AgentStore.fetchDebounce + Self.debounceSlack,
            sourceLocation: sourceLocation
        ) {
            fake.didCallMethod("agent.list")
        }
    }

    @Test func streamActivityDoesNotRefetchAgents() async throws {
        try await expectNoRefetch(after: "agent:stream:activity")
    }

    @Test func toolCallDoesNotRefetchAgents() async throws {
        try await expectNoRefetch(after: "agent:tool:call")
    }

    @Test func statusChangedRefetchesAgents() async throws {
        try await expectRefetch(after: "agent:status-changed")
    }

    @Test func updatedRefetchesAgents() async throws {
        try await expectRefetch(after: "agent:updated")
    }
}
