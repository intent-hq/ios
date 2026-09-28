import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationIncrementalDeltaTests {
    private let fixture = ConversationStreamingFixture()

    @Test(arguments: [false, true])
    func duplicateOldAndCoalescedFragmentsApplyExactlyOnce(raw: Bool) throws {
        let live = transcript()
        defer { live.reset() }
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        let frames = fixture.growth(encoding: .incremental)
        try deliver(frames[0], to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan café")
        try deliver(frames[0], to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan café")
        try deliver(frames[1], to: live, raw: raw)
        expectText(live, "Hello café 🦊", thinking: "Plan café 🦊")
        try deliver(frames[0], to: live, raw: raw)
        // An old snapshot without an echo cannot reset this registration's mode.
        try deliver(fixture.snapshot(encoding: .full), to: live, raw: raw)
        expectText(live, "Hello café 🦊", thinking: "Plan café 🦊")
        let coalesced = fixture.delta(seq: 3, updated: [
            fixture.entity(block: ["type": "text", "id": "text-1", "textDelta": " ready now"]),
            fixture.entity(block: ["type": "thinking", "id": "thinking-1", "textDelta": " ready now"])
        ])
        try deliver(coalesced, to: live, raw: raw)
        expectText(live, "Hello café 🦊 ready now", thinking: "Plan café 🦊 ready now")
        #expect(live.streamingUpdateCount == 3)
    }

    @Test(arguments: [false, true])
    func everySnapshotResetsEncodingAndReplacesPartialText(raw: Bool) throws {
        let live = transcript()
        defer { live.reset() }
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        try deliver(fixture.growth(encoding: .incremental)[0], to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan café")
        var recovery = fixture.snapshot(encoding: .incremental, echoEncoding: false)
        recovery["seq"] = 2
        try deliver(recovery, to: live, raw: raw)
        expectText(live, "Hello", thinking: "Plan")
        // No echo: ignore fragment-only blocks instead of appending or erasing text.
        try deliver(fixture.growth(encoding: .incremental)[2], to: live, raw: raw)
        expectText(live, "Hello", thinking: "Plan")
        try deliver(textFrame(seq: 4, field: "text", text: "full replacement"), to: live, raw: raw)
        expectText(live, "full replacement", thinking: "Plan")
        recovery = fixture.snapshot(encoding: .incremental)
        recovery["seq"] = 5
        try deliver(recovery, to: live, raw: raw)
        try deliver(textFrame(seq: 6, field: "textDelta", text: " resumed"), to: live, raw: raw)
        expectText(live, "Hello resumed", thinking: "Plan")
    }

    @Test(arguments: [false, true])
    func addedThenUpdatedInOneFrameAndFullAuthorityConverge(raw: Bool) throws {
        let empty = ConversationStreamingFixture(startsWithPartial: false)
        let live = transcript()
        defer { live.reset() }
        try deliver(empty.snapshot(encoding: .incremental), to: live, raw: raw)
        let first = fixture.entity(block: ["id": "text-1", "type": "text", "textDelta": "first"])
        let second = fixture.entity(block: ["id": "text-1", "type": "text", "textDelta": " second"])
        try deliver(fixture.delta(seq: 1, added: [first], updated: [second]), to: live, raw: raw)
        expectText(live, "first second", thinking: nil)
        try deliver(textFrame(seq: 2, field: "text", text: "corrected"), to: live, raw: raw)
        expectText(live, "corrected", thinking: nil)
        try deliver(textFrame(seq: 3, field: "textDelta", text: " tail"), to: live, raw: raw)
        expectText(live, "corrected tail", thinking: nil)
        let final = fixture.delta(seq: 4, updated: [
            fixture.entity(block: ["id": "text-1", "type": "text", "text": "authoritative final"], streamingComplete: true)
        ])
        try deliver(final, to: live, raw: raw)
        expectText(live, "authoritative final", thinking: nil)
        #expect(!live.isStreaming && live.messages.first?.isStreaming == false)
        #expect(live.streamingUpdateCount == 0)
    }

    @Test(arguments: [false, true])
    func oldDaemonSnapshotKeepsFullEncodingForEveryFrame(raw: Bool) throws {
        let live = transcript()
        defer { live.reset() }
        try deliver(fixture.snapshot(encoding: .incremental, echoEncoding: false), to: live, raw: raw)
        for (index, frame) in fixture.growth(encoding: .full).enumerated() {
            try deliver(frame, to: live, raw: raw)
            let suffix = fixture.fragments[...index].joined()
            expectText(live, fixture.textPrefix + suffix, thinking: fixture.thinkingPrefix + suffix)
        }
    }

    @Test(arguments: [false, true])
    func gapRecoversThroughOneSubscriptionAndRejectsOldChannel(raw: Bool) async throws {
        let connection = RPCRecordingConnection()
        connection.responseMap["chat.subscribe"] = ["subscriptionId": ConversationStreamingFixture.subscriptionId]
        connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        let live = ConversationLiveTranscript(connectionManager: connection)
        defer { live.reset() }
        await live.subscribe(agentId: ConversationStreamingFixture.agentId)
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        try deliver(fixture.growth(encoding: .incremental)[0], to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan café")
        connection.responseMap["chat.subscribe"] = ["subscriptionId": "recovered"]
        let gap = fixture.growth(encoding: .incremental)[2]
        try deliver(gap, to: live, raw: raw)
        try deliver(gap, to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan café")
        try await waitUntil("gap recovery registered") { live.chatSubscriptionId == "recovered" }
        #expect(connection.paramsForMethod("chat.subscribe").count == 2)
        #expect(connection.paramsForMethod("chat.unsubscribe").count == 1)
        try deliver(fixture.growth(encoding: .incremental)[1], to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan café")
        var snapshot = fixture.snapshot(encoding: .incremental)
        snapshot["subscriptionId"] = "recovered"
        try deliver(snapshot, to: live, raw: raw)
        expectText(live, "Hello", thinking: "Plan")
        for (index, var frame) in fixture.growth(encoding: .incremental).enumerated() {
            frame["subscriptionId"] = "recovered"
            try deliver(frame, to: live, raw: raw)
            let suffix = fixture.fragments[...index].joined()
            expectText(live, "Hello" + suffix, thinking: "Plan" + suffix)
        }
        try finishTurn(live, subscriptionId: "recovered", raw: raw)
        #expect(!connection.didCallMethod("agent.getConversation"))
        #expect(!connection.didCallMethod("agent.getMessageBlock"))
    }

    @Test(arguments: [false, true])
    func reconnectNeedsANewEchoAndIgnoresOldPushes(raw: Bool) async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["chat.subscribe"] = ["subscriptionId": ConversationStreamingFixture.subscriptionId]
        connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        let live = ConversationLiveTranscript(connectionManager: connection)
        defer { live.reset() }
        await live.subscribe(agentId: ConversationStreamingFixture.agentId)
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        try deliver(fixture.growth(encoding: .incremental)[0], to: live, raw: raw)
        live.prepareForReconnect()
        connection.responseMap["chat.subscribe"] = ["subscriptionId": "reconnect"]
        await live.subscribe(agentId: ConversationStreamingFixture.agentId)
        try deliver(fixture.growth(encoding: .incremental)[1], to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan café")
        var snapshot = fixture.snapshot(encoding: .full)
        snapshot["subscriptionId"] = "reconnect"
        try deliver(snapshot, to: live, raw: raw)
        var fragment = fixture.growth(encoding: .incremental)[0]
        fragment["subscriptionId"] = "reconnect"
        try deliver(fragment, to: live, raw: raw)
        expectText(live, "Hello", thinking: "Plan")
        var full = fixture.growth(encoding: .full)[1]
        full["subscriptionId"] = "reconnect"
        try deliver(full, to: live, raw: raw)
        expectText(live, "Hello café 🦊", thinking: "Plan café 🦊")
        full = fixture.growth(encoding: .full)[2]
        full["subscriptionId"] = "reconnect"
        try deliver(full, to: live, raw: raw)
        expectText(live, fixture.finalText, thinking: fixture.finalThinking)
        try finishTurn(live, subscriptionId: "reconnect", raw: raw)
    }

    @Test(arguments: [false, true])
    func nonTextSparseToolsAndRemovedBlocksKeepExistingSemantics(raw: Bool) throws {
        let live = transcript()
        defer { live.reset() }
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        let nonText: [[String: Any]] = fixture.toolBlocks + [
            ["id": "image", "type": "image", "data": "aW1hZ2U=", "mimeType": "image/png"],
            ["id": "file", "type": "file", "attachmentId": "attachment", "fileName": "a.txt"],
            ["id": "resource", "type": "resource", "resource": ["text": "resource text"], "textDelta": "ignored"]
        ]
        try deliver(fixture.delta(seq: 1, added: nonText.map { fixture.entity(block: $0) }), to: live, raw: raw)
        let blocks = try #require(live.messages.first?.contentBlocks)
        #expect(Array(blocks.dropFirst(2)) == nonText.compactMap { ContentBlock.decode($0) })
        let sparse = fixture.entity(block: ["id": "tool-use", "type": "tool_use", "toolCallId": "call-1", "name": ""])
        try deliver(fixture.delta(seq: 2, updated: [sparse]), to: live, raw: raw)
        let tool = live.messages.first?.contentBlocks.first { $0.id == "tool-use" }
        #expect(tool?.resolvedName == "read_file")
        #expect(tool?.input["path"]?.stringValue == "café.txt")
        var removal = fixture.delta(seq: 3)
        removal["delta"] = ["removedIds": ["image", "resource"]]
        try deliver(removal, to: live, raw: raw)
        #expect(live.messages.first?.contentBlocks.map(\.id) == ["text-1", "thinking-1", "tool-use", "tool-result", "file"])
    }

    @Test(arguments: [false, true])
    func hydratedToolSurvivesFragmentsAndTerminalWithoutEagerReads(raw: Bool) async throws {
        let connection = RPCRecordingConnection()
        let live = transcript(connection)
        live.bind(agentId: ConversationStreamingFixture.agentId, workspaceId: nil)
        defer { live.reset() }
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        let tool = fixture.entity(block: fixture.toolBlocks[1])
        try deliver(fixture.delta(seq: 1, added: [tool]), to: live, raw: raw)
        #expect(connection.traffic().requests.isEmpty)
        connection.responseMap["agent.getMessageBlock"] = [
            "block": ["id": "tool-result", "type": "tool_result", "toolUseId": "call-1", "output": "full hydrated output"]
        ]
        await live.hydrateBlock(messageId: ConversationStreamingFixture.messageId, blockId: "tool-result")
        try deliver(textFrame(seq: 2, field: "textDelta", text: " café"), to: live, raw: raw)
        expectText(live, "Hello café", thinking: "Plan")
        try deliver(fixture.delta(seq: 3, updated: [tool]), to: live, raw: raw)
        #expect(live.messages.first?.contentBlocks.last?.output?.stringValue == "full hydrated output")
        var terminal = fixture.terminal
        terminal["seq"] = 4
        try deliver(terminal, to: live, raw: raw)
        expectText(live, fixture.finalText, thinking: fixture.finalThinking)
        #expect(live.messages.first?.contentBlocks.first { $0.id == "tool-result" }?.output?.stringValue == "full hydrated output")
        #expect(connection.traffic().methodCounts == ["agent.getMessageBlock": 1])
    }

    @Test(arguments: [false, true])
    func hydratedTextCannotMaskLaterFragmentsOrAuthority(raw: Bool) async throws {
        let connection = FakeConnectionManager()
        let live = transcript(connection)
        live.bind(agentId: ConversationStreamingFixture.agentId, workspaceId: nil)
        defer { live.reset() }
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        connection.responseMap["agent.getMessageBlock"] = [
            "block": ["id": "text-1", "type": "text", "text": "hydrated text"]
        ]
        await live.hydrateBlock(messageId: ConversationStreamingFixture.messageId, blockId: "text-1")
        expectText(live, "hydrated text", thinking: "Plan")
        try deliver(textFrame(seq: 1, field: "textDelta", text: " tail"), to: live, raw: raw)
        expectText(live, "hydrated text tail", thinking: "Plan")
        await live.hydrateBlock(messageId: ConversationStreamingFixture.messageId, blockId: "text-1")
        try deliver(textFrame(seq: 2, field: "text", text: "authority"), to: live, raw: raw)
        expectText(live, "authority", thinking: "Plan")
        await live.hydrateBlock(messageId: ConversationStreamingFixture.messageId, blockId: "text-1")
        var recovery = fixture.snapshot(encoding: .incremental)
        recovery["seq"] = 3
        try deliver(recovery, to: live, raw: raw)
        expectText(live, "Hello", thinking: "Plan")
    }

    @Test(arguments: [false, true])
    func lateTextHydrationCannotEraseGrowth(raw: Bool) async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.getMessageBlock"]
        let live = transcript(connection)
        live.bind(agentId: ConversationStreamingFixture.agentId, workspaceId: nil)
        defer { live.reset() }
        try deliver(fixture.snapshot(encoding: .incremental), to: live, raw: raw)
        let hydration = Task {
            await live.hydrateBlock(messageId: ConversationStreamingFixture.messageId, blockId: "text-1")
        }
        try await connection.waitForPendingRequests("agent.getMessageBlock")
        try deliver(textFrame(seq: 1, field: "textDelta", text: " tail"), to: live, raw: raw)
        expectText(live, "Hello tail", thinking: "Plan")
        connection.resolvePending("agent.getMessageBlock", with: [
            "block": ["id": "text-1", "type": "text", "text": "Hello"]
        ])
        await hydration.value
        expectText(live, "Hello tail", thinking: "Plan")
        #expect(!live.isBlockHydrated(messageId: ConversationStreamingFixture.messageId, blockId: "text-1"))
    }

    private func transcript(_ connection: ConnectionManagerRouting = FakeConnectionManager()) -> ConversationLiveTranscript {
        let live = ConversationLiveTranscript(connectionManager: connection)
        live.setTestChannel(subscriptionId: ConversationStreamingFixture.subscriptionId)
        return live
    }

    private func textFrame(seq: Int, field: String, text: String) -> [String: Any] {
        fixture.delta(seq: seq, updated: [fixture.entity(block: ["id": "text-1", "type": "text", field: text])])
    }

    private func finishTurn(_ live: ConversationLiveTranscript, subscriptionId: String, raw: Bool) throws {
        for var frame in [fixture.toolFrame, fixture.terminal] {
            frame["subscriptionId"] = subscriptionId
            try deliver(frame, to: live, raw: raw)
        }
        let expected = try #require(ConversationMessage.parseMessage(fixture.authoritativeMessage))
        #expect(live.messages.first?.contentBlocks == expected.contentBlocks)
        #expect(live.messages.first?.timestamp == expected.timestamp)
        #expect(!live.isStreaming)
    }

    private func expectText(_ live: ConversationLiveTranscript, _ text: String, thinking: String?) {
        #expect(live.messages.first?.contentBlocks.first { $0.id == "text-1" }?.resolvedText == text)
        #expect(live.messages.first?.contentBlocks.first { $0.id == "thinking-1" }?.resolvedText == thinking)
    }

    private func deliver(_ frame: [String: Any], to live: ConversationLiveTranscript, raw: Bool) throws {
        let id = try #require(frame["subscriptionId"] as? String)
        let seq = try #require(frame["seq"] as? Int)
        if !raw {
            live.handlePush(try #require(SubscriptionPush.parse(method: "subscription.push", params: frame)))
        } else if let delta = frame["delta"] as? [String: Any] {
            live.handlePush(SubscriptionPush(subscriptionId: id, seq: seq, delta: .init(
                added: delta["added"] as? [[String: Any]] ?? [],
                updated: delta["updated"] as? [[String: Any]] ?? [],
                removedIds: delta["removedIds"] as? [String] ?? []
            )))
        } else {
            var snapshot = try #require(frame["snapshot"] as? [String: Any])
            let rows = try #require(snapshot.removeValue(forKey: "messages") as? [[String: Any]])
            live.handlePush(SubscriptionPush(
                subscriptionId: id, kind: .snapshot, seq: seq, snapshot: rows, delta: nil, snapshotMeta: snapshot
            ))
        }
    }
}
