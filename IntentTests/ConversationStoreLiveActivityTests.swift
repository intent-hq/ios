import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

extension ConversationStoreLiveStateTests {
    @Test func sparseProgressTickPreservesPriorToolBlockFields() throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:0",
                "name": "view",
                "input": ["_acpTitle": "Read `src/main.rs`"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "started"]
            ])
        ]))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:0",
                "name": "",
                "input": [String: Any](),
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "started"]
            ])
        ]))

        var block = try #require(store.messages.first?.contentBlocks.first)
        #expect(block.resolvedName == "view")
        #expect(block.input["_acpTitle"]?.value as? String == "Read `src/main.rs`")
        #expect(block.metadata["toolKind"]?.value as? String == "read")

        var display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == .file)
        #expect(display.verb == "Read")
        #expect(display.subject == "main.rs")

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 3, updated: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:0",
                "name": "",
                "input": [String: Any](),
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "completed"]
            ])
        ]))

        block = try #require(store.messages.first?.contentBlocks.first)
        #expect(block.resolvedName == "view")
        #expect(block.input["_acpTitle"]?.value as? String == "Read `src/main.rs`")
        #expect(block.metadata["status"]?.value as? String == "completed")

        display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.verb == "Read")
        #expect(display.subject == "main.rs")
    }

    // MARK: - User-row deltas (intentd#747)

    @Test func userRowDeltaAppendsUserMessage() throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-u1",
                block: ["type": "text", "id": "msg-u1:0", "text": "Queued message"],
                role: "user",
                streamingComplete: true,
                messageSeq: 3,
                timestamp: "2026-06-27T01:00:02.000Z"
            )
        ]))

        #expect(store.messages.count == 1)
        let user = try #require(store.messages.first)
        #expect(user.id == "msg-u1")
        #expect(user.role == .user)
        #expect(user.isStreaming == false)
        #expect(user.timestamp == "2026-06-27T01:00:02.000Z")
        #expect(user.contentBlocks.count == 1)
        #expect(user.contentBlocks.first?.resolvedText == "Queued message")
        #expect(store.isStreaming == false)
    }

    @Test func userRowDeltaRedeliveryDoesNotDuplicate() {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        let entity = blockEntity(
            messageId: "msg-u1",
            block: ["type": "text", "id": "msg-u1:0", "text": "Queued message"],
            role: "user",
            streamingComplete: true
        )
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [entity]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [entity]))

        #expect(store.messages.count == 1)
        #expect(store.messages.first?.contentBlocks.count == 1)
        #expect(store.messages.first?.contentBlocks.first?.resolvedText == "Queued message")
    }

    @Test func userRowDeltaDoesNotDuplicateOptimisticLocalAppend() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(agentId: "agent-1", content: "Hello", workspaceId: "ws-1")

        #expect(store.messages.count == 1)
        let messageId = try #require(store.messages.first?.id)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: messageId,
                block: ["type": "text", "id": "\(messageId):0", "text": "Hello"],
                role: "user",
                streamingComplete: true,
                timestamp: "2026-06-27T01:00:02.000Z"
            )
        ]))

        #expect(store.messages.count == 1)
        let user = try #require(store.messages.first)
        #expect(user.role == .user)
        #expect(user.contentBlocks.count == 1)
        #expect(user.contentBlocks.first?.resolvedText == "Hello")
    }

    @Test func multiBlockUserRowDeltaUpsertsOverOptimisticAppend() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(
            agentId: "agent-1",
            content: "See this",
            workspaceId: "ws-1",
            imagePayload: .attachments([["type": "image", "data": "aGk=", "mimeType": "image/png"]])
        )

        #expect(store.messages.count == 1)
        let messageId = try #require(store.messages.first?.id)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: messageId,
                block: ["type": "text", "id": "\(messageId):0", "text": "See this"],
                role: "user",
                streamingComplete: true
            ),
            blockEntity(
                messageId: messageId,
                block: [
                    "type": "image",
                    "id": "\(messageId):1",
                    "data": "aGk=",
                    "mimeType": "image/png"
                ],
                role: "user",
                streamingComplete: true
            )
        ]))

        #expect(store.messages.count == 1)
        let blocks = try #require(store.messages.first?.contentBlocks)
        #expect(blocks.count == 2)
        #expect(blocks[0].type == .text)
        #expect(blocks[0].resolvedText == "See this")
        #expect(blocks[1].type == .image)
    }
}

extension ConversationStoreLiveStateTests {
    @Test func userRowTerminalDeltaDoesNotClearTurnStreaming() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(agentId: "agent-1", content: "Hello", workspaceId: "ws-1")
        #expect(store.isStreaming == true)

        let messageId = try #require(store.messages.first?.id)
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: messageId,
                block: ["type": "text", "id": "\(messageId):0", "text": "Hello"],
                role: "user",
                streamingComplete: true
            )
        ]))

        #expect(store.isStreaming == true)
    }

    // MARK: - Enriched agent:stream:activity preview payload (watched agents)

    private func makeWatchedAgent(
        id: String,
        lastAgentResponse: String? = nil,
        lastUserMessage: String? = nil,
        lastMessageRole: String? = nil,
        digest: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            name: "Delegate",
            status: "responding",
            isBackground: false,
            isStreaming: true,
            isProcessing: false,
            isResponding: true,
            isWaitingForOtherAgents: false,
            waitingForAgentIds: [],
            createdAt: nil,
            updatedAt: nil,
            lastActivity: nil,
            lastAgentResponse: lastAgentResponse,
            lastUserMessage: lastUserMessage,
            lastMessageRole: lastMessageRole,
            digest: digest,
            specialist: nil,
            createdByAgentId: nil,
            attentionRequestKind: nil,
            attentionRequestReason: nil,
            attentionRequestTimestamp: nil
        )
    }

    private func makeParentStore(watching childId: String) async -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot()
        await store.subscribeLiveChat(agentId: "agent-parent", workspaceId: "ws-1")
        store.watchedAgentIds = [childId]
        store.watchedAgents = [makeWatchedAgent(id: childId, lastAgentResponse: "Old preview")]
        store.isWaitingForAgents = true
        fake.clearRequestLog()
        return (store, fake)
    }

    private func drainMainQueue() async {
        let drainYieldCount = 20
        for _ in 0..<drainYieldCount { await Task.yield() }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let conditionCheckLimit = 200
        let retryDelayNanoseconds: UInt64 = 10_000_000
        for _ in 0..<conditionCheckLimit {
            if condition() { return }
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }

    @Test func enrichedActivityAppliesPreviewToWatchedAgentWithoutRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Running the tests now",
                    "digest": "Running unit tests"
                ]
            ]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Running the tests now")
        #expect(watched.digest == "Running unit tests")
        #expect(watched.displayMessage == "Running unit tests")
        #expect(!fake.didCallMethod("agent.get"))
        #expect(store.isStreaming == false)
        #expect(store.messages.isEmpty)
    }

    @Test func enrichedActivityPartialPayloadPreservesExistingFields() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")
        store.watchedAgents = [makeWatchedAgent(id: "agent-child", digest: "Prior digest")]

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Partial turn text"
                ]
            ]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Partial turn text")
        #expect(watched.digest == "Prior digest")
        #expect(!fake.didCallMethod("agent.get"))
    }

    @Test func enrichedActivityDigestOnlyPreservesLastAgentResponse() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "digest": "Fresh digest"
                ]
            ]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == "Fresh digest")
        #expect(watched.displayMessage == "Fresh digest")
        #expect(!fake.didCallMethod("agent.get"))
    }

    @Test func enrichedActivityFlipsUserNewestPreviewToAgentText() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")
        store.watchedAgents = [
            makeWatchedAgent(
                id: "agent-child",
                lastUserMessage: "Please also update the docs",
                lastMessageRole: "user"
            )
        ]
        #expect(store.watchedAgents.first?.displayMessage == "Please also update the docs")

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Updating the docs now"
                ]
            ]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastMessageRole == "assistant")
        #expect(watched.displayMessage == "Updating the docs now")
        #expect(!fake.didCallMethod("agent.get"))
    }

    @Test func contentFreeActivityForLoadedAgentDoesNotRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1"
                ]
            ]
        ])
        await drainMainQueue()

        #expect(!fake.didCallMethod("agent.get"))
        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == nil)
    }
}

extension ConversationStoreLiveStateTests {
    @Test func enrichedActivityForOffscreenWatchedAgentDoesNotRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")
        store.watchedAgents = []
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "agent-child",
                "name": "Delegate",
                "status": "responding",
                "isStreaming": true,
                "lastAgentResponse": "Loaded"
            ]
        ]

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Preview text",
                    "digest": "Digest text"
                ]
            ]
        ])
        try await expectNever("offscreen activity detail read") { fake.didCallMethod("agent.get") }
        #expect(fake.paramsForMethod("agent.get").isEmpty)
        #expect(store.watchedAgents.first?.id == "agent-child")
        #expect(store.watchedAgents.first?.status == "unknown")
    }

    @Test func activityFromUnrelatedAgentStillDropped() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-stranger",
                    "messageId": "m-1",
                    "lastAgentResponse": "Should not apply",
                    "digest": "Nope"
                ]
            ]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == nil)
        #expect(!fake.didCallMethod("agent.get"))
        #expect(store.isStreaming == false)
    }
}
