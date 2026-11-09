import Foundation
@testable import Intent
import Testing

/// ios#462: each list's first read is not started, loading, loaded (empty or
/// not), or failed, and Retry after a failure loads the list.
@MainActor
struct ListLoadPhaseTests {
    private static let offline = NSError(
        domain: "WebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
    )

    // MARK: - LoadPhase

    @Test func phaseKeepsTheLastSuccessThroughARefreshAndItsFailure() {
        let loadedAt = Date(timeIntervalSince1970: 1)
        let idle = LoadPhase.idle
        #expect(idle.isAwaitingFirstLoad && !idle.isLoading)
        let first = idle.beginning()
        #expect(first == .loading(lastLoadedAt: nil) && first.isAwaitingFirstLoad)
        let failed = first.failing(Self.offline)
        #expect(failed == .failed("Request timed out") && !failed.isAwaitingFirstLoad)
        #expect(failed.beginning() == .loading(lastLoadedAt: nil), "Retry starts a fresh first read")
        let refresh = LoadPhase.loaded(loadedAt).beginning()
        #expect(refresh == .loading(lastLoadedAt: loadedAt) && refresh.hasLoaded)
        #expect(refresh.failing(Self.offline) == .loaded(loadedAt), "a failed refresh keeps the shown data")
        #expect(refresh.settled() == .loaded(loadedAt))
        #expect(first.settled() == .idle, "a read that ended without a result is not started again")
        #expect(failed.settled() == failed)
    }

    // MARK: - NoteStore

    private func note(_ id: String) -> [String: Any] {
        ["id": id, "title": id, "content": "", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
    }

    @Test func notesMoveFromLoadingToLoadedOrEmpty() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        #expect(store.loadPhase == .idle)
        fake.pendingMethods.insert("note.list")
        let fetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list")
        #expect(store.loadPhase == .loading(lastLoadedAt: nil))
        fake.resolvePending("note.list", with: ["notes": [note("spec")]])
        await fetch.value
        #expect(store.hasLoaded && !store.isLoading)
        #expect(store.notes.map(\.id) == ["spec"])

        fake.pendingMethods = []
        fake.responseMap["note.list"] = ["notes": []]
        await store.fetchNotes(workspaceId: "ws-2")
        #expect(store.hasLoaded && store.notes.isEmpty, "a successful empty read shows the empty state")
    }

    @Test func failedFirstNoteReadReportsAnErrorAndRetryLoads() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.list"] = Self.offline
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.loadPhase == .failed("Request timed out"))

        fake.errorMap["note.list"] = nil
        fake.responseMap["note.list"] = ["notes": [note("spec")]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded && store.loadPhase.failureMessage == nil)
        #expect(store.notes.map(\.id) == ["spec"])

        fake.errorMap["note.list"] = Self.offline
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded && store.notes.map(\.id) == ["spec"], "a failed refresh keeps cached notes")

        store.prepareForWorkspaceChange(to: "ws-2")
        #expect(store.loadPhase == .idle)
    }

    // MARK: - AgentStore

    @Test func agentsMoveFromNotStartedToFailedAndRetryToLoaded() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        #expect(store.loadPhase == .idle)
        fake.errorMap["agent.list"] = Self.offline
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.loadPhase == .failed("Request timed out"))
        #expect(!store.loadPhase.isAwaitingFirstLoad)

        fake.errorMap["agent.list"] = nil
        fake.pendingMethods.insert("agent.list")
        let retry = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        #expect(store.loadPhase == .loading(lastLoadedAt: nil), "Retry shows loading, not the old error")
        fake.resolvePending("agent.list", with: ["agents": [["id": "agent-1", "name": "Agent 1"]]])
        await retry.value
        #expect(store.hasLoaded && !store.isLoading)
        #expect(store.agents.map(\.id) == ["agent-1"])
    }

    @Test func emptyAgentReadIsLoadedAndAFailedRefreshKeepsIt() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["agent.list"] = ["agents": []]
        await store.fetchAgents(workspaceId: "ws-1")
        let loadedAt = store.loadPhase.lastLoadedAt
        #expect(loadedAt != nil && store.agents.isEmpty)

        fake.errorMap["agent.list"] = Self.offline
        await store._fetchAgents(workspaceId: "ws-1")
        #expect(store.loadPhase.lastLoadedAt == loadedAt, "a failed refresh keeps the empty state")
    }

    // MARK: - WorkspaceStore

    @Test func workspacesMoveFromLoadingToLoadedOrEmpty() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["workspace.list"]
        let store = WorkspaceStore(connectionManager: fake)
        #expect(store.loadPhase == .idle && store.lastUpdated == nil)
        let fetch = Task { await store.fetchAll() }
        try await fake.waitForPendingRequests("workspace.list")
        #expect(store.loadPhase == .loading(lastLoadedAt: nil))
        fake.resolvePending("workspace.list", with: ["workspaces": [["id": "ws-1", "title": "One"]]])
        await fetch.value
        #expect(store.lastUpdated != nil && !store.isLoading)
        #expect(store.workspaces.map(\.id) == ["ws-1"])

        fake.pendingMethods = []
        fake.responseMap["workspace.list"] = ["workspaces": []]
        await store.fetchAll()
        #expect(store.lastUpdated != nil && store.workspaces.isEmpty, "a successful empty read shows the empty state")
    }

    @Test func failedFirstWorkspaceReadReportsAnErrorAndRetryLoads() async {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.errorMap["workspace.list"] = Self.offline
        await store.fetchAll()
        #expect(store.loadPhase == .failed("Request timed out"))
        #expect(store.lastUpdated == nil && !store.isLoading)

        fake.errorMap["workspace.list"] = nil
        fake.responseMap["workspace.list"] = ["workspaces": [["id": "ws-1", "title": "One"]]]
        await store.fetchIfNeeded()
        #expect(store.lastUpdated != nil && store.loadPhase.failureMessage == nil)

        fake.errorMap["workspace.list"] = Self.offline
        await store.fetchAll()
        #expect(store.lastUpdated != nil && store.workspaces.map(\.id) == ["ws-1"], "a failed refresh keeps cached rows")
    }

    @Test func forgettingWorkspacesKeepsARunningReadLoading() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["workspace.list"]
        let store = WorkspaceStore(connectionManager: fake)
        store.publishFetchedWorkspaces([])
        let fetch = Task { await store.fetchAll() }
        try await fake.waitForPendingRequests("workspace.list")
        store.forgetPublishedWorkspaces()
        #expect(store.loadPhase == .loading(lastLoadedAt: nil))
        fake.resolvePending("workspace.list", with: ["workspaces": []])
        await fetch.value
        #expect(store.lastUpdated != nil && !store.isLoading)
        store.forgetPublishedWorkspaces()
        #expect(store.loadPhase == .idle)
    }

    // MARK: - Workspace list view model

    @Test func workspaceListReportsAFailureOnlyWhileNothingIsShown() async {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        let viewModel = WorkspaceListViewModel(workspaceStore: store)
        fake.errorMap["workspace.list"] = Self.offline
        await store.fetchAll()
        #expect(viewModel.loadFailureMessage == "Request timed out")
        fake.errorMap["workspace.list"] = nil
        fake.responseMap["workspace.list"] = ["workspaces": [["id": "ws-1", "title": "One"]]]
        await viewModel.retryLoad()
        #expect(viewModel.loadFailureMessage == nil)
        #expect(viewModel.workspaces.map(\.id) == ["ws-1"])
    }
}
