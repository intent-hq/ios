import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

extension ConversationStoreLiveStateTests {
    @Test func terminalFrameTimestampAdopted() {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-1",
                block: ["type": "text", "id": "msg-1:0", "text": "Working"]
            )
        ]))
        #expect(store.messages.count == 1)
        #expect(!store.messages[0].timestamp.isEmpty)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(
                messageId: "msg-1",
                block: ["type": "text", "id": "msg-1:0", "text": "Working done"],
                streamingComplete: true,
                timestamp: "2026-06-27T01:00:05.000Z"
            )
        ]))
        #expect(store.messages[0].timestamp == "2026-06-27T01:00:05.000Z")
    }

    // MARK: - Firehose gating while chat channel is live

    @Test func firehoseActivityIgnoredWhenChatLive() {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.messages.count == 1)

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["streamId": "s-1"]]
        ])
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["messageId": "m-1"]]
        ])

        #expect(store.messages.count == 1)
        #expect(store.isStreaming == false)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Real content"]
            )
        ]))
        #expect(store.messages.count == 2)
        #expect(store.messages[1].contentBlocks.count == 1)
        #expect(store.messages[1].contentBlocks.first?.resolvedText == "Real content")
    }

    @Test func firehoseActivityRaisesStreamingWhenChatNotLive() {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["messageId": "m-1"]]
        ])

        #expect(store.messages.isEmpty)
        #expect(store.isStreaming == true)

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:end", "data": ["streamId": "s-1"]]
        ])
        #expect(store.messages.isEmpty)
        #expect(store.isStreaming == false)
    }

    @Test func firehoseStreamEndLeavesTheLiveChannelsRowsAlone() {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Partial"]
            )
        ]))
        #expect(store.messages[0].isStreaming == true)
        #expect(store.isStreaming == true)

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:end", "data": ["streamId": "s-1"]]
        ])

        #expect(store.messages[0].isStreaming == true)
        #expect(store.isStreaming == true)
        #expect(store.streamingUpdateCount == 1)
    }

    @Test func failedResubscribeClearsChatLiveSoFirehoseApplies() async {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.messages.count == 1)

        await store.subscribeLiveChat(agentId: "agent-1")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["agentId": "agent-1", "streamId": "s-1"]]
        ])
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["agentId": "agent-1", "messageId": "m-1"]]
        ])

        #expect(store.messages.count == 1)
        #expect(store.isStreaming == true)
    }

    // MARK: - Stale-seq tolerance

    @Test func staleSeqDeltaIgnoredWithoutResubscribe() async throws {
        let (store, fake) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Working"]
            )
        ]))
        #expect(store.messages.count == 1)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-stale",
                block: ["type": "text", "id": "msg-stale:0", "text": "dup"]
            )
        ]))

        try await expectNever("resnapshot for a stale entity") {
            fake.didCallMethod("chat.unsubscribe") || fake.didCallMethod("chat.subscribe")
        }
        #expect(store.messages.count == 1)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Working more"]
            )
        ]))
        #expect(store.messages[0].contentBlocks.first?.resolvedText == "Working more")
    }

    @Test func gapAheadStillResnapshotsExactlyOnce() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["chat.unsubscribe"] = [String: Any]()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 5, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "lost"]
            )
        ]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 6, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:1", "text": "also lost"]
            )
        ]))

        try await fake.waitForRequests("chat.unsubscribe")
        try await expectNever("second resnapshot while one is in flight") {
            fake.paramsForMethod("chat.unsubscribe").count > 1
        }
        #expect(store.messages.isEmpty)
    }
}

extension ConversationStoreLiveStateTests {
    @Test func staleSnapshotRedeliveryIgnoredAfterDeltasApplied() async throws {
        let (store, fake) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Working"]
            )
        ]))
        #expect(store.messages.count == 1)

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        #expect(store.messages.count == 1)
        #expect(store.messages[0].id == "msg-2")

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Working more"]
            )
        ]))
        #expect(store.messages[0].contentBlocks.first?.resolvedText == "Working more")
        try await expectNever("resnapshot for an in-sequence delta") {
            fake.didCallMethod("chat.unsubscribe")
        }
    }

    // MARK: - Mid-turn tool title classification (STAB: generic spanner fallback)

    @Test func midTurnFileReadToolWithAcpTitleOnlyClassifiesAsRead() throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:0",
                "name": "view",
                "input": ["_acpTitle": "Read `crates/intent-core/src/lib.rs`"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "started"]
            ])
        ]))

        let block = try #require(store.messages.first?.contentBlocks.first)
        #expect(block.type == .toolUse)
        #expect(block.input["_acpTitle"]?.value as? String == "Read `crates/intent-core/src/lib.rs`")

        let display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == .file)
        #expect(display.verb == "Read")
        #expect(display.subject == "lib.rs")
        #expect(display.path == "crates/intent-core/src")
    }

    @Test func workspaceApiWithAcpTitleUsesTitleAsLabel() {
        let display = ToolClassifier.classify(name: "workspace_api", input: [
            "_acpTitle": AnyCodable("Read spec and task note")
        ])
        #expect(display.icon != .tool)
        #expect(display.verb == "Read spec and task note")
    }

    @Test func codexWorkspaceApiSnapshotUsesSummary() throws {
        let (store, _) = makeStore()
        let summary = "Inspect the coordinates of the swipes recorded by hosted UI tests"
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "assistant",
                "contentBlocks": [
                    [
                        "type": "tool_use",
                        "id": "msg-1:0",
                        "name": "mcp.workspace-mcp.workspace_api",
                        "input": [
                            "_acpTitle": "mcp.workspace-mcp.workspace_api",
                            "code": "return await ws.workspace.details()",
                            "summary": summary
                        ],
                        "toolCallId": "call-1",
                        "metadata": ["toolKind": "other", "status": "completed"]
                    ]
                ],
                "timestamp": "2026-09-26T00:00:00.000Z"
            ]
        ]))

        let block = try #require(store.messages.first?.contentBlocks.first)
        #expect(block.type == .toolUse)
        #expect(block.input["summary"]?.value as? String == summary)
        let display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == .workspace)
        #expect(display.verb == summary)
        #expect(display.subject == nil)
    }

    @Test func codexWorkspaceApiLiveUpdateReplacesRawTitleWithSummary() throws {
        let (store, _) = makeStore()
        let title = "mcp.workspace-mcp.workspace_api"
        let summary = "Inspect the coordinates of the swipes recorded by hosted UI tests"
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-1", block: [
                "type": "tool_use",
                "id": "msg-1:0",
                "name": "workspace_api",
                "input": ["_acpTitle": title],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "started"]
            ])
        ]))
        let initialBlock = try #require(store.messages.first?.contentBlocks.first)
        let initialDisplay = ToolClassifier.classify(name: initialBlock.resolvedName ?? "tool", input: initialBlock.input)
        #expect(initialDisplay.verb == title)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-1", block: [
                "type": "tool_use",
                "id": "msg-1:0",
                "name": "workspace_api",
                "input": [
                    "_acpTitle": title,
                    "code": "return await ws.workspace.details()",
                    "summary": summary
                ],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "completed"]
            ])
        ]))

        #expect(store.messages.count == 1)
        #expect(store.messages.first?.contentBlocks.count == 1)
        let updatedBlock = try #require(store.messages.first?.contentBlocks.first)
        #expect(updatedBlock.id == initialBlock.id)
        let updatedDisplay = ToolClassifier.classify(name: updatedBlock.resolvedName ?? "tool", input: updatedBlock.input)
        #expect(updatedDisplay.icon == .workspace)
        #expect(updatedDisplay.verb == summary)
        #expect(updatedDisplay.subject == nil)
    }

    @Test func unrecognizedToolWithProseAcpTitleUsesTitleVerbatim() {
        let display = ToolClassifier.classify(name: "zz_unrecognized_tool", input: [
            "_acpTitle": AnyCodable("Summarize recent activity for the user")
        ])
        #expect(display.verb == "Summarize recent activity for the user")
        #expect(display.subject == nil)
    }

    @Test func nonProseAcpTitleKeepsCleanedNameFallback() {
        let display = ToolClassifier.classify(name: "zz_unrecognized_tool", input: [
            "_acpTitle": AnyCodable("zz_unrecognized_tool")
        ])
        #expect(display.icon == .tool)
        #expect(display.verb == "Zz Unrecognized Tool")
    }

    @Test func readToolWithQuotedExtensionlessFilenameClassifiesAsRead() {
        let display = ToolClassifier.classify(name: "view", input: [
            "_acpTitle": AnyCodable("Read `LICENSE`")
        ])
        #expect(display.icon == .file)
        #expect(display.verb == "Read")
        #expect(display.subject == "LICENSE")
    }

    @Test func editToolWithAcpTitleOnlyExtractsPath() {
        let display = ToolClassifier.classify(name: "str-replace-editor", input: [
            "_acpTitle": AnyCodable("Edit `src/foo/bar.ts`")
        ])
        #expect(display.icon == .edit)
        #expect(display.verb == "Edit")
        #expect(display.subject == "bar.ts")
        #expect(display.path == "src/foo")
    }

    @Test func completedUpdatedToolBlockReplacesInputAndReclassifies() throws {
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
                "name": "view",
                "input": ["_acpTitle": "Read `other.rs`", "path": "src/main.rs"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "completed"]
            ])
        ]))

        let block = try #require(store.messages.first?.contentBlocks.first)
        #expect(block.input["path"]?.value as? String == "src/main.rs")

        let display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == .file)
        #expect(display.verb == "Read")
        #expect(display.subject == "main.rs")
    }
}
