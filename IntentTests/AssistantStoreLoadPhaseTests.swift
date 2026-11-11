import Foundation
@testable import Intent
import Testing

/// Assistant history is one `LoadPhase`; create and delete failures are kept apart in `actionFailure`.
@MainActor
struct AssistantStoreLoadPhaseTests {
    private static let offline = NSError(
        domain: "WebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
    )

    private func thread(_ id: String) -> [String: Any] {
        ["id": id, "name": "Assistant", "updatedAt": "2026-09-24T10:00:00Z"]
    }

    @Test func movesFromLoadingToLoaded() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.list"]
        let store = AssistantStore(connection: connection)
        let load = Task { await store.refresh() }
        try await connection.waitForPendingRequests("agent.list")
        #expect(store.loadPhase == .loading(lastLoadedAt: nil))
        #expect(store.errorMessage == nil)

        connection.resolvePending("agent.list", with: ["agents": [thread("first")]])
        await load.value
        #expect(store.loadPhase.hasLoaded && !store.isLoading)
        #expect(store.threads.map(\.id) == ["first"])
    }

    @Test func emptyHistoryIsLoadedNotFailed() async {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [] as [[String: Any]]]
        let store = AssistantStore(connection: connection)
        await store.refresh()
        #expect(store.loadPhase.hasLoaded && store.threads.isEmpty && store.errorMessage == nil)
    }

    @Test func aFailedFirstLoadIsFailedNotLoading() async {
        let connection = FakeConnectionManager()
        connection.errorMap["agent.list"] = Self.offline
        let store = AssistantStore(connection: connection)
        await store.refresh()
        #expect(store.loadPhase == .failed("Request timed out"))
        #expect(!store.isLoading && !store.hasLoaded)
    }

    @Test func aFailedRefreshKeepsRowsAndTheMessageUntilRetryStarts() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [thread("existing")]]
        let store = AssistantStore(connection: connection)
        await store.refresh()
        let loadedAt = try #require(store.loadPhase.lastLoadedAt)
        connection.errorMap["agent.list"] = Self.offline

        await store.refresh()
        #expect(store.loadPhase == .refreshFailed("Request timed out", lastLoadedAt: loadedAt))
        #expect(store.threads.map(\.id) == ["existing"])
        #expect(store.errorMessage == "Request timed out")

        connection.errorMap.removeValue(forKey: "agent.list")
        connection.pendingMethods = ["agent.list"]
        let retry = Task { await store.refresh() }
        try await connection.waitForPendingRequests("agent.list")
        #expect(store.loadPhase == .loading(lastLoadedAt: loadedAt), "Retry shows loading, not the old error")
        #expect(store.errorMessage == nil && store.threads.map(\.id) == ["existing"])
        connection.resolvePending("agent.list", with: ["agents": [thread("replacement")]])
        await retry.value
        #expect(store.threads.map(\.id) == ["replacement"] && store.errorMessage == nil)
    }

    @Test func aFailedDeleteIsAnActionFailureThatAListReadClears() async {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [thread("existing")]]
        let store = AssistantStore(connection: connection)
        await store.refresh()
        connection.errorMap["agent.delete"] = Self.offline

        #expect(await store.deleteThread("existing") == false)
        #expect(store.actionFailure == "Request timed out")
        #expect(store.loadPhase.hasLoaded && store.loadPhase.anyFailureMessage == nil)
        #expect(store.errorMessage == "Request timed out")

        await store.refresh()
        #expect(store.actionFailure == nil && store.errorMessage == nil)
    }

    @Test func startingACreationDismissesARefreshFailure() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [thread("existing")]]
        let store = AssistantStore(connection: connection)
        await store.refresh()
        let loadedAt = try #require(store.loadPhase.lastLoadedAt)
        connection.errorMap["agent.list"] = Self.offline
        await store.refresh()
        connection.responseMap["agent.create"] = ["agent": thread("created")]

        _ = await store.createThread()
        #expect(store.loadPhase == .loaded(loadedAt))
        #expect(store.errorMessage == nil)
    }
}
