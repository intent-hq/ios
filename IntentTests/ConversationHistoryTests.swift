import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationHistoryTests {
    private func message(_ id: String, text: String? = nil) -> [String: Any] {
        [
            "id": id, "role": "assistant", "timestamp": "2026-01-01T00:00:00Z",
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": text ?? id]]
        ]
    }

    private func page(_ ids: [String], cursor: String? = nil) -> [String: Any] {
        ["messages": ids.map { message($0) }, "nextToken": cursor as Any? ?? NSNull(), "truncated": cursor != nil]
    }

    private func makeStore(cursor: String? = "before-3") async -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        fake.stubChatSnapshot(messages: [message("3"), message("4")], meta: [
            "nextToken": cursor as Any? ?? NSNull(), "truncated": cursor != nil, "totalMessages": 4
        ])
        let store = ConversationStore(connectionManager: fake)
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        return (store, fake)
    }

    private func snapshot(
        _ store: ConversationStore, ids: [String], cursor: String? = nil, resumed: Bool = false
    ) {
        store.handleChatSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            conversationSnapshot: ids.map { message($0, text: "new-\($0)") },
            metadata: [
                "nextToken": cursor as Any? ?? NSNull(), "truncated": cursor != nil,
                "resumed": resumed, "totalMessages": 8
            ]
        ))
    }

    @Test func snapshotCursorDrivesOrderedDeduplicatedPagingToEnd() async throws {
        let (store, fake) = await makeStore()
        #expect(store.hasOlderMessages)
        #expect(!store.isLoadingOlderMessages)
        fake.responseMap["agent.getConversation"] = [
            "messages": [message("1"), message("2"), message("2"), message("3", text: "stale")],
            "nextToken": "before-1", "truncated": true
        ]

        await store.loadOlderMessages()

        #expect(store.messages.map(\.id) == ["1", "2", "3", "4"])
        #expect(store.messages[2].contentBlocks.first?.text == "3")
        #expect(store.hasOlderMessages)
        let request = try #require(fake.paramsForMethod("agent.getConversation").first)
        #expect(request["agentId"] as? String == "agent-1")
        #expect(request["workspaceId"] as? String == "ws-1")
        #expect(request["nextToken"] as? String == "before-3")
        #expect(request["limit"] as? Int == 50)
        #expect(request["projection"] as? String == "slim")

        fake.responseMap["agent.getConversation"] = page(["0"])
        await store.loadOlderMessages()
        #expect(store.messages.map(\.id) == ["0", "1", "2", "3", "4"])
        #expect(!store.hasOlderMessages)
        #expect(!store.isTruncated)
        #expect(!store.isLoadingOlderMessages)
        #expect(store.olderMessagesError == nil)
        #expect(fake.paramsForMethod("agent.getConversation").last?["nextToken"] as? String == "before-1")
        await store.loadOlderMessages()
        #expect(fake.paramsForMethod("agent.getConversation").count == 2)
    }

    @Test func prependCapturesLatestReadingIntentBeforePublishingRows() async throws {
        let (store, fake) = await makeStore()
        fake.pendingMethods.insert("agent.getConversation")
        var readingMessage = "4"
        var capturedMessage: String?
        var residentAtCapture: [String] = []
        let pending = Task {
            await store.loadOlderMessages {
                capturedMessage = readingMessage
                residentAtCapture = store.messages.map(\.id)
            }
        }
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(capturedMessage == nil)
        readingMessage = "3"
        fake.resolvePending("agent.getConversation", with: page(["1", "2"]))
        await pending.value
        #expect(capturedMessage == "3")
        #expect(residentAtCapture == ["3", "4"])
        #expect(store.messages.map(\.id) == ["1", "2", "3", "4"])
    }

    @Test func snapshotWithoutCursorDoesNotRequestHistory() async {
        let (store, fake) = await makeStore(cursor: nil)
        await store.loadOlderMessages()
        #expect(!store.hasOlderMessages)
        #expect(fake.paramsForMethod("agent.getConversation").isEmpty)
    }

    @Test func overlappingCallsIssueOnlyOneRequest() async throws {
        let (store, fake) = await makeStore()
        fake.pendingMethods.insert("agent.getConversation")
        let first = Task { await store.loadOlderMessages() }
        try await fake.waitForPendingRequests("agent.getConversation")
        #expect(store.isLoadingOlderMessages)

        await store.loadOlderMessages()

        #expect(fake.paramsForMethod("agent.getConversation").count == 1)
        #expect(store.isLoadingOlderMessages)
        fake.resolvePending("agent.getConversation", with: page(["1", "2"]))
        await first.value
        #expect(!store.isLoadingOlderMessages)
        #expect(store.messages.map(\.id) == ["1", "2", "3", "4"])
    }

    @Test(arguments: [false, true])
    func bindingChangeDropsPendingPage(reset: Bool) async throws {
        let (store, fake) = await makeStore()
        fake.pendingMethods.insert("agent.getConversation")
        let pending = Task { await store.loadOlderMessages() }
        try await fake.waitForPendingRequests("agent.getConversation")
        if reset { store.reset() }
        fake.stubChatSnapshot(messages: [message("other")], meta: ["nextToken": "other-cursor", "truncated": true])
        await store.subscribeLiveChat(agentId: reset ? "agent-1" : "agent-2", workspaceId: "ws-1")

        fake.resolvePending("agent.getConversation", with: page(["stale"]))
        await pending.value

        #expect(store.messages.map(\.id) == ["other"])
        #expect(store.hasOlderMessages)
        #expect(!store.isLoadingOlderMessages)
        #expect(store.olderMessagesError == nil)
    }

    @Test func localAgentBindingInvalidatesHistoryBeforeNewSubscription() async throws {
        let (store, fake) = await makeStore()
        fake.pendingMethods.insert("agent.getConversation")
        let pending = Task { await store.loadOlderMessages() }
        try await fake.waitForPendingRequests("agent.getConversation")
        store.bindStreaming(agentId: "agent-2", workspaceId: "ws-1")
        fake.resolvePending("agent.getConversation", with: page(["stale"]))
        await pending.value
        #expect(store.messages.map(\.id) == ["3", "4"])
        #expect(!store.hasOlderMessages)
        #expect(!store.isLoadingOlderMessages)
    }

    @Test(arguments: [false, true])
    func snapshotInvalidatesPendingResultWithoutClearingNewLoader(fails: Bool) async throws {
        let (store, fake) = await makeStore()
        fake.pendingMethods.insert("agent.getConversation")
        let stale = Task { await store.loadOlderMessages() }
        try await fake.waitForPendingRequests("agent.getConversation")
        snapshot(store, ids: ["7", "8"], cursor: "before-7")
        let current = Task { await store.loadOlderMessages() }
        try await fake.waitForPendingRequests("agent.getConversation", count: 2)
        if fails {
            fake.failPending("agent.getConversation", with: URLError(.notConnectedToInternet))
        } else {
            fake.resolvePending("agent.getConversation", with: page(["stale"]))
        }
        await stale.value
        #expect(store.isLoadingOlderMessages)
        #expect(store.olderMessagesError == nil)
        #expect(store.messages.map(\.id) == ["7", "8"])
        fake.resolvePending("agent.getConversation", with: page(["5", "6"]))
        await current.value
        #expect(!store.isLoadingOlderMessages)
        #expect(store.messages.map(\.id) == ["5", "6", "7", "8"])
        #expect(fake.paramsForMethod("agent.getConversation").last?["nextToken"] as? String == "before-7")
    }

    @Test(arguments: [false, true])
    func connectedSnapshotKeepsOlderPrefixAndItsCursor(exhausted: Bool) async {
        let (store, fake) = await makeStore()
        fake.responseMap["agent.getConversation"] = page(["1", "2"], cursor: exhausted ? nil : "before-1")
        await store.loadOlderMessages()

        snapshot(store, ids: ["3", "5"], cursor: "before-3")

        #expect(store.messages.map(\.id) == ["1", "2", "3", "5"])
        #expect(store.messages[2].contentBlocks.first?.text == "new-3")
        #expect(store.hasOlderMessages == !exhausted)
        #expect(store.isTruncated == !exhausted)
        #expect(store.totalMessageCount == 8)
        fake.responseMap["agent.getConversation"] = page(["0"])
        await store.loadOlderMessages()
        #expect(fake.paramsForMethod("agent.getConversation").count == (exhausted ? 1 : 2))
        if !exhausted {
            #expect(fake.paramsForMethod("agent.getConversation").last?["nextToken"] as? String == "before-1")
        }
    }

    @Test func disjointSnapshotResetsLoadedPagesAndCursor() async {
        let (store, fake) = await makeStore()
        fake.responseMap["agent.getConversation"] = page(["1", "2"])
        await store.loadOlderMessages()
        snapshot(store, ids: ["7", "8"], cursor: "before-7")
        #expect(store.messages.map(\.id) == ["7", "8"])
        #expect(store.hasOlderMessages)
        fake.responseMap["agent.getConversation"] = page(["5", "6"])
        await store.loadOlderMessages()
        #expect(fake.paramsForMethod("agent.getConversation").last?["nextToken"] as? String == "before-7")
    }

    @Test(arguments: [false, true])
    func resumedSnapshotPreservesUnloadedHistory(empty: Bool) async {
        let (store, fake) = await makeStore()
        snapshot(store, ids: empty ? [] : ["4", "5"], resumed: true)
        #expect(store.messages.map(\.id) == (empty ? ["3", "4"] : ["3", "4", "5"]))
        #expect(store.hasOlderMessages)
        #expect(store.isTruncated)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1)
        fake.responseMap["agent.getConversation"] = page(["1", "2"])
        await store.loadOlderMessages()
        #expect(fake.paramsForMethod("agent.getConversation").last?["nextToken"] as? String == "before-3")
    }
}

extension ConversationHistoryTests {
    @Test func resumedSnapshotOwnsStreamingStateDespiteRetainedRows() async {
        let (store, fake) = await makeStore()
        var streaming = message("4")
        streaming["isStreaming"] = true
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 0,
            conversationSnapshot: [message("3"), streaming],
            metadata: ["nextToken": "before-3", "truncated": true]
        ))
        #expect(store.isStreaming)
        snapshot(store, ids: ["5"], resumed: true)
        #expect(store.messages.map(\.id) == ["3", "4", "5"])
        #expect(!store.isStreaming)
        #expect(store.hasOlderMessages)
    }

    @Test(arguments: [false, true])
    func loadFailureLeavesCursorRetryable(malformed: Bool) async {
        let (store, fake) = await makeStore()
        if malformed {
            fake.responseMap["agent.getConversation"] = ["messages": "invalid"]
        } else {
            fake.errorMap["agent.getConversation"] = URLError(.notConnectedToInternet)
        }
        await store.loadOlderMessages()
        #expect(store.olderMessagesError != nil)
        #expect(!store.isLoadingOlderMessages)
        #expect(store.hasOlderMessages)
        #expect(store.messages.map(\.id) == ["3", "4"])
        fake.errorMap["agent.getConversation"] = nil
        fake.responseMap["agent.getConversation"] = page(["1", "2"])
        await store.loadOlderMessages()
        #expect(store.olderMessagesError == nil)
        #expect(!store.hasOlderMessages)
        #expect(store.messages.map(\.id) == ["1", "2", "3", "4"])
        #expect(fake.paramsForMethod("agent.getConversation").map { $0["nextToken"] as? String } == ["before-3", "before-3"])
    }

    @Test func cancelledLoadIsRetryableWithoutShowingAnError() async throws {
        let (store, fake) = await makeStore()
        fake.pendingMethods.insert("agent.getConversation")
        let pending = Task { await store.loadOlderMessages() }
        try await fake.waitForPendingRequests("agent.getConversation")
        pending.cancel()
        await pending.value
        #expect(!store.isLoadingOlderMessages)
        #expect(store.hasOlderMessages)
        #expect(store.olderMessagesError == nil)
        fake.pendingMethods.remove("agent.getConversation")
        fake.responseMap["agent.getConversation"] = page(["1", "2"])
        await store.loadOlderMessages()
        #expect(store.messages.map(\.id) == ["1", "2", "3", "4"])
    }

    @Test func prependedToolBlocksHydrateAndSurviveConnectedSnapshot() async throws {
        let (store, fake) = await makeStore()
        let block: [String: Any] = [
            "type": "tool_result", "id": "tool", "toolUseId": "call", "output": "preview", "outputTruncated": true
        ]
        fake.responseMap["agent.getConversation"] = [
            "messages": [["id": "1", "role": "assistant", "contentBlocks": [block]]], "nextToken": NSNull()
        ]
        await store.loadOlderMessages()
        fake.responseMap["agent.getMessageBlock"] = [
            "block": ["type": "tool_result", "id": "tool", "toolUseId": "call", "output": "full"]
        ]
        await store.hydrateBlock(messageId: "1", blockId: "tool")
        snapshot(store, ids: ["3", "4"], cursor: "before-3")
        let older = try #require(store.messages.first)
        #expect(older.id == "1")
        #expect(older.contentBlocks.first?.output?.value as? String == "full")
        #expect(store.isBlockHydrated(messageId: "1", blockId: "tool"))
        await store.hydrateBlock(messageId: "1", blockId: "tool")
        #expect(fake.paramsForMethod("agent.getMessageBlock").count == 1)
    }
}
