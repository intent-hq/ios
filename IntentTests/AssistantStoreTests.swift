import Foundation
@testable import Intent
import Testing

@MainActor
struct AssistantStoreTests {
    private func thread(_ id: String, date: String = "2026-09-24T10:00:00Z") -> [String: Any] {
        ["id": id, "name": "Assistant", "updatedAt": date]
    }

    @Test func loadsGlobalHistoryInActivityOrder() async {
        let connection = FakeConnectionManager()
        var child = thread("child")
        child["metadata"] = ["createdByAgentId": "parent"]
        connection.responseMap["agent.list"] = [
            "agents": [thread("older", date: "2026-09-23T10:00:00Z"), child, thread("latest")]
        ]
        let store = AssistantStore(connection: connection)

        await store.refresh()

        #expect(store.threads.map(\.id) == ["latest", "older"])
        #expect(store.hasLoaded)
        #expect(connection.paramsForMethod("agent.list").first?["workspaceId"] as? String == "__chief__")
        #expect(!connection.didCallMethod("agent.create"))
    }

    @Test func failedRefreshPreservesHistoryAndCanRetry() async {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [thread("existing")]]
        let store = AssistantStore(connection: connection)
        await store.refresh()
        connection.errorMap["agent.list"] = NSError(domain: "Test", code: 1)

        await store.refresh()

        #expect(store.threads.map(\.id) == ["existing"])
        #expect(store.errorMessage != nil)
        #expect(!store.isLoading)
        connection.errorMap.removeValue(forKey: "agent.list")
        connection.responseMap["agent.list"] = ["agents": [thread("replacement")]]
        await store.refresh()
        #expect(store.threads.map(\.id) == ["replacement"])
        #expect(store.errorMessage == nil)
    }

    @Test func malformedHistoryDoesNotBecomeAnEmptySuccess() async {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["unexpected": true]
        let store = AssistantStore(connection: connection)
        await store.refresh()
        #expect(!store.hasLoaded)
        #expect(store.errorMessage != nil)
        #expect(!connection.didCallMethod("agent.create"))
    }

    @Test func newChatUsesGlobalSpecialistAndRetriesWithSameKey() async throws {
        let connection = FakeConnectionManager()
        connection.errorMap["agent.create"] = NSError(domain: "Test", code: 1)
        let store = AssistantStore(connection: connection)
        #expect(await store.createThread() == nil)
        let first = try #require(connection.paramsForMethod("agent.create").first)
        connection.errorMap.removeValue(forKey: "agent.create")
        connection.responseMap["agent.create"] = ["agent": thread("created")]

        #expect(await store.createThread() == "created")

        let retry = try #require(connection.paramsForMethod("agent.create").last)
        #expect(retry["workspaceId"] as? String == "__chief__")
        #expect(retry["specialistId"] as? String == "chief-of-staff")
        #expect(retry["idempotencyKey"] as? String == first["idempotencyKey"] as? String)
        #expect(retry["provider"] == nil)
        #expect(retry["model"] == nil)
        #expect(store.threads.map(\.id) == ["created"])
        #expect(store.errorMessage == nil)

        _ = await store.createThread()
        let next = try #require(connection.paramsForMethod("agent.create").last)
        #expect(next["idempotencyKey"] as? String != first["idempotencyKey"] as? String)
    }

    @Test func concurrentCreationDoesNotCreateDuplicateChats() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.create"]
        let store = AssistantStore(connection: connection)
        let first = Task { await store.createThread() }
        try await waitUntil("Assistant creation request") { connection.pendingRequestCount("agent.create") == 1 }
        #expect(await store.createThread() == nil)
        connection.resolvePending("agent.create", with: ["agent": thread("created")])
        #expect(await first.value == "created")
        #expect(connection.paramsForMethod("agent.create").count == 1)
    }

    @Test func storesDoNotShareBackendHistory() async {
        let firstConnection = FakeConnectionManager()
        let secondConnection = FakeConnectionManager()
        firstConnection.responseMap["agent.list"] = ["agents": [thread("first-backend")]]
        secondConnection.responseMap["agent.list"] = ["agents": [thread("second-backend")]]
        let first = AssistantStore(connection: firstConnection)
        let second = AssistantStore(connection: secondConnection)
        await first.refresh()
        await second.refresh()
        #expect(first.threads.map(\.id) == ["first-backend"])
        #expect(second.threads.map(\.id) == ["second-backend"])
    }

    @Test func observesConnectionEventsOnlyAfterFirstUse() async {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": []]
        let store = AssistantStore(connection: connection)
        #expect(connection.eventHandlerCount == 0, "an unopened Assistant must not observe the connection")

        await store.refresh()
        await store.refresh()

        #expect(connection.eventHandlerCount == 1)
    }

    @Test func globalThreadEventsRefreshHistory() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [thread("deleted")]]
        let store = AssistantStore(connection: connection)
        await store.refresh()
        connection.responseMap["agent.list"] = ["agents": [thread("remaining")]]
        connection.deliverEvent(method: "workspace.event", params: [
            "event": ["type": "agent:deleted", "workspaceId": Workspace.chiefWorkspaceId]
        ])
        try await waitUntil("updated Assistant history") { store.threads.map(\.id) == ["remaining"] }
    }

    @Test func refreshRequestedDuringLoadReadsAgain() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.list"]
        let store = AssistantStore(connection: connection)
        let load = Task { await store.refresh() }
        try await waitUntil("initial Assistant history request") { connection.pendingRequestCount("agent.list") == 1 }
        await store.refresh()
        connection.resolvePending("agent.list", with: ["agents": [thread("stale")]])
        try await waitUntil("coalesced Assistant history request") {
            connection.paramsForMethod("agent.list").count == 2
        }
        connection.resolvePending("agent.list", with: ["agents": [thread("fresh")]])
        await load.value
        #expect(store.threads.map(\.id) == ["fresh"])
        #expect(!store.isLoading)
    }
}
