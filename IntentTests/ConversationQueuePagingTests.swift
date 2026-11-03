import Foundation
@testable import Intent
import Testing

/// `agent.getQueue` against a bounded daemon (protocol "Paged agent lists and
/// queues"): entries keep drain order and whole-queue positions across pages.
/// The token is a queue position, so a walk overtaken by `agent:queue:updated`
/// stops, and any re-read starts from the first page.
@MainActor
struct ConversationQueuePagingTests {
    private static func entries(_ range: ClosedRange<Int>) -> [[String: Any]] {
        range.map { index in
            ["id": "q-\(index)", "content": "entry \(index)", "queuedAt": "2026-11-03T00:00:00Z", "position": index - 1]
        }
    }

    private static func page(_ entries: [[String: Any]], next: String?, length: Int = 0) -> [String: Any] {
        ["queue": entries, "queueLength": length, "nextToken": next.map { $0 as Any } ?? NSNull()]
    }

    private static let previous = [
        QueuedMessage(id: "q-old", content: "previous", queuedAt: "2026-11-02T00:00:00Z", position: 0)
    ]

    /// A store with a live chat subscription, so queue events reach it.
    private func liveStore() async -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot()
        fake.responseMap["agent.getQueue"] = ["queue": [] as [Any], "nextToken": NSNull()]
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "a", workspaceId: "w")
        fake.responseMap["agent.getQueue"] = nil
        fake.requestLog.removeAll()
        return (store, fake)
    }

    private func queueUpdated(_ store: ConversationStore, queue: Any) {
        store.handleStreamEvent("events.event", params: [
            "event": ["type": "agent:queue:updated", "data": ["agentId": "a", "queue": queue] as [String: Any]] as [String: Any]
        ])
    }

    @Test func fetchQueueReadsEveryPageInDrainOrder() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseQueueMap["agent.getQueue"] = [
            Self.page(Self.entries(1...200), next: "t1", length: 251),
            Self.page(Self.entries(201...251), next: "t2", length: 251),
            Self.page([], next: nil, length: 251)
        ]

        await store.fetchQueue(agentId: "agent-1")

        #expect(store.queuedMessages.count == 251)
        #expect(store.queuedMessages.map(\.position) == Array(0...250), "Positions are whole-queue")
        #expect(store.queuedMessages.last?.id == "q-251")
        let sent = fake.paramsForMethod("agent.getQueue")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1", "t2"])
        #expect(sent.allSatisfy { $0["agentId"] as? String == "agent-1" && $0["limit"] as? Int == PagedReads.queuePageLimit })
    }

    @Test func pageErrorMidWalkKeepsThePreviousQueue() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.queuedMessages = Self.previous
        // The second page has no configured reply, so it fails.
        fake.responseQueueMap["agent.getQueue"] = [Self.page(Self.entries(1...200), next: "t1")]

        await store.fetchQueue(agentId: "agent-1")

        #expect(store.queuedMessages.map(\.id) == ["q-old"])
        #expect(fake.paramsForMethod("agent.getQueue").count == 2)
    }

    @Test func malformedContinuationPageKeepsThePreviousQueue() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.queuedMessages = Self.previous
        fake.responseQueueMap["agent.getQueue"] = [
            Self.page(Self.entries(1...200), next: "t1"),
            ["queue": "not-an-array", "nextToken": NSNull()]
        ]

        await store.fetchQueue(agentId: "agent-1")

        #expect(store.queuedMessages.map(\.id) == ["q-old"])
    }

    @Test func repeatedTokenKeepsThePreviousQueue() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.queuedMessages = Self.previous
        fake.responseMap["agent.getQueue"] = Self.page(Self.entries(1...1), next: "same")

        await store.fetchQueue(agentId: "agent-1")

        #expect(store.queuedMessages.map(\.id) == ["q-old"])
        #expect(fake.paramsForMethod("agent.getQueue").count == 2)
    }

    @Test func queueEventMidWalkWinsAndStopsTheWalk() async throws {
        let (store, fake) = await liveStore()
        fake.pendingMethods.insert("agent.getQueue")
        let read = Task { await store.fetchQueue(agentId: "a") }
        try await fake.waitForPendingRequests("agent.getQueue")

        queueUpdated(store, queue: Self.entries(1...3))
        fake.resolvePending("agent.getQueue", with: Self.page(Self.entries(1...200), next: "t1"))
        await read.value

        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-2", "q-3"], "The newer whole-queue event wins")
        #expect(fake.paramsForMethod("agent.getQueue").count == 1, "Positions shifted, so the walk must not read on")
    }

    @Test func unreadableQueueEventRereadsFromTheFirstPage() async throws {
        let (store, fake) = await liveStore()
        fake.pendingMethods.insert("agent.getQueue")
        let read = Task { await store.fetchQueue(agentId: "a") }
        try await fake.waitForPendingRequests("agent.getQueue")

        // An event without a readable queue asks for a fresh read.
        queueUpdated(store, queue: "not-an-array")
        fake.resolvePending("agent.getQueue", with: Self.page(Self.entries(1...200), next: "t1"))
        try await fake.waitForPendingRequests("agent.getQueue")
        fake.resolvePending("agent.getQueue", with: Self.page(Self.entries(1...2), next: nil))
        await read.value

        let sent = fake.paramsForMethod("agent.getQueue")
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0["nextToken"] == nil }, "The re-read starts from the first page")
        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-2"])
    }
}
