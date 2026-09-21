import Combine
import Foundation
@testable import Intent
import Testing

extension ConversationStoreIntegrationTests {
    /// `deliverSubscriptionPush` invokes the registered handler synchronously
    /// on the main actor, so the push is applied when this returns.
    private func deliver(
        _ push: SubscriptionPush,
        through fake: FakeConnectionManager
    ) {
        fake.deliverSubscriptionPush(push)
    }

    private func slimMessage(containing block: [String: Any]) -> [String: Any] {
        [
            "id": "msg-1",
            "role": "assistant",
            "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [block]
        ]
    }

    private func seedLiveConversation(
        _ store: ConversationStore,
        through fake: FakeConnectionManager,
        snapshot: [[String: Any]]
    ) async throws {
        fake.stubChatSnapshot(messages: snapshot)
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        try await waitUntil("chat.subscribe handler registration") { fake.hasSubscriptionHandler(id: "sub-1") }
    }

    // MARK: - Slim projection (PROTOCOL §5.5) + block hydration

    @Test func subscribeLiveChatRequestsSlimProjection() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]

        await store.subscribeLiveChat(agentId: "agent-1")

        let params = fake.paramsForMethod("chat.subscribe")
        #expect(params.count == 1)
        #expect(params.first?["projection"] as? String == "slim")
    }

    @Test func hydrateBlockMergesFullBlockIntoTranscript() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Seed a transcript with a slim-truncated tool_result block.
        fake.stubChatSnapshot(messages: [
            [
                "id": "msg-1",
                "role": "assistant",
                "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    ["type": "tool_use", "id": "b-1", "name": "read_file", "toolCallId": "tc-1"],
                    [
                        "type": "tool_result",
                        "id": "b-2",
                        "toolUseId": "tc-1",
                        "output": "preview…",
                        "outputTruncated": true,
                        "outputBytes": 900_000
                    ]
                ]
            ]
        ])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.messages.first?.contentBlocks[1].outputTruncation == .truncated)

        // Hydrate: the daemon returns the FULL block (no truncation flags).
        fake.responseMap["agent.getMessageBlock"] = [
            "block": [
                "type": "tool_result",
                "id": "b-2",
                "toolUseId": "tc-1",
                "output": "the full output"
            ] as [String: Any]
        ]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-2")

        let params = fake.paramsForMethod("agent.getMessageBlock")
        #expect(params.count == 1)
        #expect(params.first?["agentId"] as? String == "agent-1")
        #expect(params.first?["messageId"] as? String == "msg-1")
        #expect(params.first?["blockId"] as? String == "b-2")

        let hydrated = store.messages.first?.contentBlocks[1]
        #expect(hydrated?.outputTruncation == .unreported)
        #expect((hydrated?.output?.value as? String) == "the full output")
        #expect(store.isBlockHydrated(messageId: "msg-1", blockId: "b-2"))
        #expect(store.hydratingBlockKeys.isEmpty)
    }

    @Test func hydrateBlockIsSingleFlightAndCached() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.stubChatSnapshot(messages: [
            [
                "id": "msg-1",
                "role": "assistant",
                "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    [
                        "type": "tool_result",
                        "id": "b-1",
                        "toolUseId": "tc-1",
                        "output": "preview…",
                        "outputTruncated": true
                    ]
                ]
            ]
        ])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")

        fake.responseMap["agent.getMessageBlock"] = [
            "block": [
                "type": "tool_result",
                "id": "b-1",
                "toolUseId": "tc-1",
                "output": "full"
            ] as [String: Any]
        ]
        // Two concurrent + one repeat hydration: only ONE wire fetch.
        async let first: () = store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        async let second: () = store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        _ = await (first, second)
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")

        #expect(fake.paramsForMethod("agent.getMessageBlock").count == 1)
    }

    @Test func hydratedBlockSurvivesSlimRefetchAndSnapshot() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        let slimMessage: [String: Any] = [
            "id": "msg-1",
            "role": "assistant",
            "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [
                [
                    "type": "tool_result",
                    "id": "b-1",
                    "toolUseId": "tc-1",
                    "output": "preview…",
                    "outputTruncated": true
                ]
            ]
        ]
        fake.stubChatSnapshot(messages: [slimMessage])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")

        fake.responseMap["agent.getMessageBlock"] = [
            "block": [
                "type": "tool_result",
                "id": "b-1",
                "toolUseId": "tc-1",
                "output": "full"
            ] as [String: Any]
        ]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        #expect((store.messages.first?.contentBlocks.first?.output?.value as? String) == "full")

        // A chat.subscribe (re)snapshot serving the truncated preview again
        // re-seeds the transcript — the hydrated full block must survive it.
        await store.subscribeLiveChat(agentId: "agent-1")
        #expect((store.messages.first?.contentBlocks.first?.output?.value as? String) == "full")
        #expect(store.messages.first?.contentBlocks.first?.outputTruncation == .unreported)

        // Same for a later snapshot on the live channel.
        deliver(
            SubscriptionPush(
                subscriptionId: "sub-1",
                seq: 0,
                snapshot: [slimMessage],
            ),
            through: fake
        )
        #expect((store.messages.first?.contentBlocks.first?.output?.value as? String) == "full")
    }
}

extension ConversationStoreIntegrationTests {
    @Test func hydrateBlockFailureClearsInFlightState() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.stubChatSnapshot(messages: [
            [
                "id": "msg-1",
                "role": "assistant",
                "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    [
                        "type": "tool_result",
                        "id": "b-1",
                        "toolUseId": "tc-1",
                        "output": "preview…",
                        "outputTruncated": true
                    ]
                ]
            ]
        ])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")

        fake.errorMap["agent.getMessageBlock"] = NSError(
            domain: "WebSocket",
            code: -32_603,
            userInfo: [NSLocalizedDescriptionKey: "internal error"]
        )
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")

        // Failure leaves the preview in place and the in-flight set empty so
        // the user can retry.
        #expect(store.hydratingBlockKeys.isEmpty)
        #expect(!store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))
        #expect(store.messages.first?.contentBlocks.first?.outputTruncation == .truncated)

        // Retry after the error succeeds.
        fake.errorMap.removeValue(forKey: "agent.getMessageBlock")
        fake.responseMap["agent.getMessageBlock"] = [
            "block": [
                "type": "tool_result",
                "id": "b-1",
                "toolUseId": "tc-1",
                "output": "full"
            ] as [String: Any]
        ]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        #expect((store.messages.first?.contentBlocks.first?.output?.value as? String) == "full")
    }

    @Test func resetClearsHydrationState() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.stubChatSnapshot(messages: [
            [
                "id": "msg-1",
                "role": "assistant",
                "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    [
                        "type": "tool_result",
                        "id": "b-1",
                        "toolUseId": "tc-1",
                        "output": "p",
                        "outputTruncated": true
                    ]
                ]
            ]
        ])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        fake.responseMap["agent.getMessageBlock"] = [
            "block": [
                "type": "tool_result",
                "id": "b-1",
                "toolUseId": "tc-1",
                "output": "full"
            ] as [String: Any]
        ]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        #expect(store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))

        store.reset()
        #expect(!store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))
        #expect(store.hydratingBlockKeys.isEmpty)
    }

    @Test func hydratedBlockSurvivesDeltaReupsert() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        let slimBlock: [String: Any] = [
            "type": "tool_result",
            "id": "b-1",
            "toolUseId": "tc-1",
            "output": "preview…",
            "outputTruncated": true
        ]
        let slimMessage = slimMessage(containing: slimBlock)
        // Seed the live channel (seq 0) so the following delta applies in order.
        try await seedLiveConversation(store, through: fake, snapshot: [slimMessage])

        fake.responseMap["agent.getMessageBlock"] = [
            "block": [
                "type": "tool_result",
                "id": "b-1",
                "toolUseId": "tc-1",
                "output": "full"
            ] as [String: Any]
        ]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        #expect((store.messages.first?.contentBlocks.first?.output?.value as? String) == "full")

        // A live delta re-upserting the slim (truncated) version of the
        // already-hydrated block must not revert it (third re-merge point:
        // applyChatDelta).
        deliver(
            SubscriptionPush(
                subscriptionId: "sub-1",
                seq: 1,
                delta: SubscriptionPush.DeltaPayload(
                    added: [],
                    updated: [
                        [
                            "agentId": "agent-1",
                            "messageId": "msg-1",
                            "role": "assistant",
                            "block": slimBlock
                        ]
                    ],
                    removedIds: []
                )
            ),
            through: fake
        )

        let block = store.messages.first?.contentBlocks.first
        #expect((block?.output?.value as? String) == "full")
        #expect(block?.outputTruncation == .unreported)
    }

    @Test func hydratedBlockCacheEvictsOldestBeyondCap() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // 31 slim-truncated blocks in one message (cap is 30, FE parity).
        let blocks: [[String: Any]] = (0..<31).map { i in
            [
                "type": "tool_result",
                "id": "b-\(i)",
                "toolUseId": "tc-\(i)",
                "output": "p",
                "outputTruncated": true
            ]
        }
        fake.stubChatSnapshot(messages: [
            [
                "id": "msg-1",
                "role": "assistant",
                "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": blocks
            ]
        ])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")

        for i in 0..<31 {
            fake.responseMap["agent.getMessageBlock"] = [
                "block": [
                    "type": "tool_result",
                    "id": "b-\(i)",
                    "toolUseId": "tc-\(i)",
                    "output": "full-\(i)"
                ] as [String: Any]
            ]
            await store.hydrateBlock(messageId: "msg-1", blockId: "b-\(i)")
        }

        // The oldest entry was evicted; the rest remain cached.
        #expect(!store.isBlockHydrated(messageId: "msg-1", blockId: "b-0"))
        #expect(store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))
        #expect(store.isBlockHydrated(messageId: "msg-1", blockId: "b-30"))
        // Eviction lost nothing visible: the full block was already merged
        // into the transcript.
        #expect((store.messages.first?.contentBlocks.first?.output?.value as? String) == "full-0")
        // An evicted block can be re-hydrated (new wire fetch).
        #expect(fake.paramsForMethod("agent.getMessageBlock").count == 31)
        fake.responseMap["agent.getMessageBlock"] = [
            "block": [
                "type": "tool_result",
                "id": "b-0",
                "toolUseId": "tc-0",
                "output": "full-0"
            ] as [String: Any]
        ]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-0")
        #expect(fake.paramsForMethod("agent.getMessageBlock").count == 32)
    }
}

extension ConversationStoreIntegrationTests {
    @Test func hydrateBlockResumedAfterResetDropsStaleBlock() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.stubChatSnapshot(messages: [
            [
                "id": "msg-1",
                "role": "assistant",
                "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    [
                        "type": "tool_result",
                        "id": "b-1",
                        "toolUseId": "tc-1",
                        "output": "p",
                        "outputTruncated": true
                    ]
                ]
            ]
        ])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")

        // Hold the fetch in flight, reset (agent switch) mid-flight, then let
        // it resume: the stale block must NOT be inserted into the fresh cache.
        fake.pendingMethods.insert("agent.getMessageBlock")
        let hydration = Task { await store.hydrateBlock(messageId: "msg-1", blockId: "b-1") }
        try await fake.waitForPendingRequests("agent.getMessageBlock")
        store.reset()
        fake.resolvePending("agent.getMessageBlock", with: [
            "block": [
                "type": "tool_result",
                "id": "b-1",
                "toolUseId": "tc-1",
                "output": "full"
            ] as [String: Any]
        ])
        await hydration.value

        #expect(!store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))
        #expect(store.hydratingBlockKeys.isEmpty)
    }
}
