import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

extension ConversationStoreLiveStateTests {
    @Test func terminalFrameTimestampAdopted() async {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        // First block delta carries no timestamp — a local one is synthesized.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-1",
                block: ["type": "text", "id": "msg-1:0", "text": "Working"]
            )
        ]))
        #expect(store.messages.count == 1)
        #expect(!store.messages[0].timestamp.isEmpty)

        // Terminal frame carries the server timestamp — it must be adopted.
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

    @Test func firehoseActivityIgnoredWhenChatLive() async {
        let (store, _) = makeStore()

        // Snapshot applied → chatLive; deltas own the transcript from here on.
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.messages.count == 1)

        // Firehose stream events for the same turn must NOT mutate live state —
        // chat.subscribe owns the transcript and streaming flags while chatLive.
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["streamId": "s-1"]]
        ])
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["messageId": "m-1"]]
        ])

        #expect(store.messages.count == 1)
        #expect(store.isStreaming == false)

        // The delta channel still applies normally afterwards.
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

    @Test func firehoseActivityRaisesStreamingWhenChatNotLive() async {
        // No chat.subscribe snapshot applied → chatLive is false: the firehose
        // is the only liveness signal until the channel seeds.
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // agent:stream:activity is content-free ({ agentId, messageId }) —
        // it must raise the streaming flag but never mutate the transcript.
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["messageId": "m-1"]]
        ])

        #expect(store.messages.isEmpty)
        #expect(store.isStreaming == true)

        // agent:stream:end lowers the flag it raised, still without content.
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:end", "data": ["streamId": "s-1"]]
        ])
        #expect(store.messages.isEmpty)
        #expect(store.isStreaming == false)
    }

    @Test func firehoseStreamEndLeavesTheLiveChannelsRowsAlone() async {
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

        // The channel owns the in-flight row and the streaming flag; only its
        // terminal delta settles them.
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:end", "data": ["streamId": "s-1"]]
        ])

        #expect(store.messages[0].isStreaming == true)
        #expect(store.isStreaming == true)
        #expect(store.streamingUpdateCount == 1)
    }

    @Test func failedResubscribeClearsChatLiveSoFirehoseApplies() async {
        let (store, _) = makeStore()

        // Chat channel goes live via a snapshot.
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.messages.count == 1)

        // A re-subscribe fails (no response configured → request throws).
        // The failed registration must clear chatLive so firehose events apply
        // until the backoff retry lands a channel again.
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

        // Stale re-delivery: seq 1 already applied (expected is now 2) — must be
        // silently ignored, not treated as a gap
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-stale",
                block: ["type": "text", "id": "msg-stale:0", "text": "dup"]
            )
        ]))

        try await expectNever("resnapshot for a stale entity") {
            fake.didCallMethod("chat.unsubscribe") || fake.didCallMethod("chat.subscribe")
        }
        #expect(store.messages.count == 1) // stale entity not applied

        // The live sequence continues normally after the stale frame
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

        // Gap: expected seq 1, got 5 — genuine loss, must resnapshot
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 5, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "lost"]
            )
        ]))
        // A second gapped frame while the resnapshot is in flight must not
        // trigger another one (storm guard)
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
        #expect(store.messages.isEmpty) // gapped deltas not applied
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

        // A duplicate/late seq-0 snapshot after deltas were applied would rewind
        // chatExpectedSeq and roll the transcript back — it must be ignored
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        #expect(store.messages.count == 1)
        #expect(store.messages[0].id == "msg-2")

        // The live sequence continues without a gap
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

    /// Daemon-shaped live `tool_use` delta: auggie sends `raw_input: null`, so the
    /// daemon coerces input to `{}` carrying only `_acpTitle` (tool_block.rs). The
    /// classifier must derive a meaningful title from `_acpTitle` instead of
    /// falling through to the generic .tool fallback.
    @Test func midTurnFileReadToolWithAcpTitleOnlyClassifiesAsRead() async throws {
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

    @Test func workspaceApiWithAcpTitleUsesTitleAsLabel() async {
        let display = ToolClassifier.classify(name: "workspace_api", input: [
            "_acpTitle": AnyCodable("Read spec and task note")
        ])
        #expect(display.icon != .tool)
        #expect(display.verb == "Read spec and task note")
    }

    @Test func unrecognizedToolWithProseAcpTitleUsesTitleVerbatim() async {
        let display = ToolClassifier.classify(name: "zz_unrecognized_tool", input: [
            "_acpTitle": AnyCodable("Summarize recent activity for the user")
        ])
        #expect(display.verb == "Summarize recent activity for the user")
        #expect(display.subject == nil)
    }

    /// A raw tool-name-shaped title (single token) must NOT be rendered verbatim;
    /// the cleaned-name generic fallback wins (desktop isProseToolName parity).
    @Test func nonProseAcpTitleKeepsCleanedNameFallback() async {
        let display = ToolClassifier.classify(name: "zz_unrecognized_tool", input: [
            "_acpTitle": AnyCodable("zz_unrecognized_tool")
        ])
        #expect(display.icon == .tool)
        #expect(display.verb == "Zz Unrecognized Tool")
    }

    @Test func readToolWithQuotedExtensionlessFilenameClassifiesAsRead() async {
        let display = ToolClassifier.classify(name: "view", input: [
            "_acpTitle": AnyCodable("Read `LICENSE`")
        ])
        #expect(display.icon == .file)
        #expect(display.verb == "Read")
        #expect(display.subject == "LICENSE")
    }

    @Test func editToolWithAcpTitleOnlyExtractsPath() async {
        let display = ToolClassifier.classify(name: "str-replace-editor", input: [
            "_acpTitle": AnyCodable("Edit `src/foo/bar.ts`")
        ])
        #expect(display.icon == .edit)
        #expect(display.verb == "Edit")
        #expect(display.subject == "bar.ts")
        #expect(display.path == "src/foo")
    }

    /// The completed `agent:tool:call` update arrives as an `updated` entity with
    /// fuller input; the store must replace the block so re-classification picks
    /// up the raw args mid-turn.
    @Test func completedUpdatedToolBlockReplacesInputAndReclassifies() async throws {
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
        // Title deliberately disagrees with path: raw input must win over the
        // _acpTitle fallback (pins raw-input-wins precedence).
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

    /// Regression (bare spanner): sparse `tool_call_update` ticks reach the
    /// chat.subscribe delta path as FULL blocks with every unset field mapped
    /// to its default (`name:""`, `input:{}`, `toolKind:"other"` — see the
    /// daemon's `tool_delta`/`map_tool_call_update`). Upserting such a block
    /// verbatim clobbers the titled block from first sight, and every later
    /// sparse tick keeps it clobbered — the in-flight row renders as a bare
    /// 🔧 with no title for the rest of the turn. A progress-only tick (empty
    /// name, same toolCallId) must preserve the prior block's name/input/
    /// toolKind and only adopt the new status (desktop bridge merge parity).
}
