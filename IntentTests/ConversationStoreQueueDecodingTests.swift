import Foundation
@testable import Intent
import Testing

private enum NestedImageQueueFixture {
    static let expectedImageCount = 2
    static let malformedType = 42
    static let position = 4
}

// Extracted wire fixtures intentionally keep protocol dictionaries compact.
// swiftlint:disable multiline_literal_brackets

extension ConversationStoreIntegrationTests {
    // MARK: - Queue snapshot decoding (ios#252)

    /// One malformed element (missing the required `content`) must drop only
    /// itself: the valid siblings keep their order, ids, and positions instead
    /// of the whole queue collapsing to `[]`.
    @Test func fetchQueueKeepsValidSiblingsWhenOneElementIsMalformed() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["agent.getQueue"] = ["queue": [
            ["id": "q-1", "content": "first", "queuedAt": "2025-01-01T00:00:00Z", "position": 0],
            ["id": "q-broken", "queuedAt": "2025-01-01T00:00:01Z", "position": 1],
            ["id": "q-3", "content": "third", "queuedAt": "2025-01-01T00:00:02Z", "position": 2]
        ]]

        await store.fetchQueue(agentId: "agent-1")

        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-3"])
        #expect(store.queuedMessages.map(\.position) == [0, 2])
        #expect(store.queuedMessages.map(\.content) == ["first", "third"])
    }

    /// A non-object element (e.g. `null` or a string) is malformed too and
    /// must not invalidate the array cast for its siblings.
    @Test func fetchQueueDropsNonObjectElementsButKeepsSiblings() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["agent.getQueue"] = ["queue": [
            ["id": "q-1", "content": "first", "queuedAt": "2025-01-01T00:00:00Z", "position": 0],
            "not-an-object",
            NSNull(),
            ["id": "q-4", "content": "fourth", "queuedAt": "2025-01-01T00:00:03Z", "position": 3]
        ] as [Any]]

        await store.fetchQueue(agentId: "agent-1")

        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-4"])
    }

    @Test func fetchQueueKeepsValidNestedImageSiblings() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["agent.getQueue"] = ["queue": [nestedImageQueueRow]]

        await store.fetchQueue(agentId: "agent-1")

        expectNestedImageQueue(store.queuedMessages)
        #expect(fake.paramsForMethod("agent.getQueue").count == 1)
    }

    /// A well-formed empty `queue` is an authoritative snapshot and clears
    /// the local queue — it must not be confused with malformed input.
    @Test func fetchQueueEmptyArrayClearsQueue() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.queuedMessages = [
            QueuedMessage(id: "q-stale", content: "stale", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        ]
        fake.responseMap["agent.getQueue"] = ["queue": [] as [Any]]

        await store.fetchQueue(agentId: "agent-1")

        #expect(store.queuedMessages.isEmpty)
    }

    /// Malformed envelope policy: when the response carries no `queue` array
    /// at all, the previous local queue is preserved rather than blanked.
    @Test func fetchQueueMalformedEnvelopePreservesPreviousQueue() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        let previous = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0),
            QueuedMessage(id: "q-2", content: "second", queuedAt: "2025-01-01T00:00:01Z", position: 1)
        ]

        store.queuedMessages = previous
        fake.responseMap["agent.getQueue"] = ["queue": "not-an-array"]
        await store.fetchQueue(agentId: "agent-1")
        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-2"])

        store.queuedMessages = previous
        fake.responseMap["agent.getQueue"] = ["unexpected": 1]
        await store.fetchQueue(agentId: "agent-1")
        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-2"])

        store.queuedMessages = previous
        fake.responseMap["agent.getQueue"] = "not-an-object"
        await store.fetchQueue(agentId: "agent-1")
        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-2"])
    }

    /// The `agent:queue:updated` push shares the element-tolerant decoder: a
    /// malformed element drops only itself and the snapshot is applied
    /// directly, without falling back to a re-fetch.
    @Test func queueUpdatedEventKeepsValidSiblingsWhenOneElementIsMalformed() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.getQueue"] = ["queue": [] as [Any]]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.requestLog.removeAll()

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:queue:updated",
                "data": [
                    "agentId": "a",
                    "queue": [
                        ["id": "q-1", "content": "first", "queuedAt": "2025-01-01T00:00:00Z", "position": 0],
                        ["id": "q-broken", "content": 42, "queuedAt": "2025-01-01T00:00:01Z", "position": 1],
                        ["id": "q-3", "content": "third", "queuedAt": "2025-01-01T00:00:02Z", "position": 2]
                    ] as [[String: Any]]
                ] as [String: Any]
            ] as [String: Any]
        ])

        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-3"])
        #expect(!fake.didCallMethod("agent.getQueue"))
    }

    @Test func queueUpdatedEventKeepsValidNestedImageSiblingsWithoutRefetch() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.getQueue"] = ["queue": [] as [Any]]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        fake.requestLog.removeAll()

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:queue:updated",
                "data": ["agentId": "a", "queue": [nestedImageQueueRow]] as [String: Any]
            ] as [String: Any]
        ])

        expectNestedImageQueue(store.queuedMessages)
        #expect(!fake.didCallMethod("agent.getQueue"))
    }

    /// An `agent:queue:updated` push with an empty `queue` clears the local
    /// queue directly.
    @Test func queueUpdatedEventEmptyArrayClearsQueue() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.getQueue"] = ["queue": [] as [Any]]
        let store = ConversationStore(connectionManager: fake)
        await store.fetchConversation(agentId: "a", workspaceId: "w")
        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        ]
        fake.requestLog.removeAll()

        store.handleStreamEvent("events.event", params: [
            "event": [
                "type": "agent:queue:updated",
                "data": ["agentId": "a", "queue": [] as [Any]] as [String: Any]
            ] as [String: Any]
        ])

        #expect(store.queuedMessages.isEmpty)
        #expect(!fake.didCallMethod("agent.getQueue"))
    }

    private var nestedImageQueueRow: [String: Any] {
        [
            "id": "q-images",
            "content": "unchanged text",
            "queuedAt": "2025-01-01T00:00:04Z",
            "position": NestedImageQueueFixture.position,
            "imageBlocks": [
                ["type": "image", "data": "inline", "mimeType": "image/png"],
                ["type": NestedImageQueueFixture.malformedType],
                ["type": "image", "attachmentId": "att-2"]
            ],
            "messageMetadata": ["userAppMessageId": "uam-1"]
        ]
    }

    private func expectNestedImageQueue(_ messages: [QueuedMessage]) {
        #expect(messages.count == 1)
        #expect(messages.first?.id == "q-images")
        #expect(messages.first?.content == "unchanged text")
        #expect(messages.first?.queuedAt == "2025-01-01T00:00:04Z")
        #expect(messages.first?.position == NestedImageQueueFixture.position)
        #expect(messages.first?.imageBlocks.count == NestedImageQueueFixture.expectedImageCount)
        #expect(messages.first?.imageBlocks.first?.data == "inline")
        #expect(messages.first?.imageBlocks.last?.attachmentId == "att-2")
        #expect(messages.first?.messageMetadata["userAppMessageId"]?.stringValue == "uam-1")
    }
}

// swiftlint:enable multiline_literal_brackets
