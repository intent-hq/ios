import Foundation
@testable import Intent
import Testing

struct DeltaSubscriptionTests {
    // MARK: - SubscriptionPush parsing

    @Test func parseSnapshotPush() {
        let params: [String: Any] = [
            "subscriptionId": "sub-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                ["id": "ws-1", "title": "Workspace 1"],
                ["id": "ws-2", "title": "Workspace 2"]
            ]
        ]

        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push != nil)
        #expect(push?.subscriptionId == "sub-123")
        #expect(push?.seq == 0)
        #expect(push?.snapshot?.count == 2)
        #expect(push?.snapshotMeta == nil) // Array snapshots carry no metadata
        #expect(push?.snapshotMessages == nil) // Only chat snapshots are pre-decoded
    }

    @Test func parseObjectSnapshotPush() throws {
        // Chat channel seq-0 snapshot: object with messages + metadata/activity flags (PROTOCOL §7.1)
        let params: [String: Any] = [
            "subscriptionId": "sub-chat",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                "agentId": "agent-123",
                "messages": [
                    [
                        "id": "0190a1b2-user",
                        "agentId": "agent-123",
                        "seq": 0,
                        "role": "user",
                        "contentBlocks": [["type": "text", "id": "0190a1b2-user:0", "text": "Run the tests"]],
                        "timestamp": "2026-06-27T01:00:00.000Z"
                    ]
                ],
                "truncated": false,
                "totalMessages": 1,
                "nextToken": NSNull(),
                "isResponding": true,
                "isWaitingOnTool": false,
                "turnInFlight": true,
                "lastStreamActivityAt": "2026-06-27T01:00:05.000Z"
            ]
        ]

        let push = try #require(SubscriptionPush.parse(method: "subscription.push", params: params))
        #expect(push.subscriptionId == "sub-chat")
        #expect(push.kind == .snapshot)
        #expect(push.seq == 0)
        #expect(push.snapshot?.count == 1)
        #expect(push.snapshot?.first?["id"] as? String == "0190a1b2-user")

        let meta = push.snapshotMeta
        #expect(meta != nil)
        #expect(meta?["agentId"] as? String == "agent-123")
        #expect(meta?["truncated"] as? Bool == false)
        #expect(meta?["totalMessages"] as? Int == 1)
        #expect(meta?["isResponding"] as? Bool == true)
        #expect(meta?["isWaitingOnTool"] as? Bool == false)
        #expect(meta?["turnInFlight"] as? Bool == true)
        #expect(meta?["lastStreamActivityAt"] as? String == "2026-06-27T01:00:05.000Z")
        #expect(meta?["messages"] == nil) // messages are lifted into .snapshot, not duplicated in meta

        // Chat snapshot rows are pre-decoded at parse time (off MainActor in
        // the live pump) so the transcript only merges typed values.
        let messages = try #require(push.snapshotMessages)
        #expect(messages.count == 1)
        #expect(messages.first?.id == "0190a1b2-user")
        #expect(messages.first?.role == .user)
        #expect(messages.first?.timestamp == "2026-06-27T01:00:00.000Z")
        #expect(messages.first?.contentBlocks.count == 1)
        #expect(messages.first?.contentBlocks.first?.id == "0190a1b2-user:0")
        #expect(messages.first?.contentBlocks.first?.type == .text)
        #expect(messages.first?.contentBlocks.first?.resolvedText == "Run the tests")
    }

    @Test func parseObjectSnapshotDropsUndecodableRows() {
        let params: [String: Any] = [
            "subscriptionId": "sub-chat",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                "agentId": "agent-123",
                "messages": [
                    ["role": "user", "contentBlocks": [["type": "text", "text": "no id"]]],
                    ["id": "m-2", "role": "assistant", "contentBlocks": [["type": "text", "text": "ok"]]]
                ]
            ]
        ]

        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push?.snapshot?.count == 2) // raw rows pass through untouched
        #expect(push?.snapshotMessages?.map(\.id) == ["m-2"])
    }

    @Test func parseObjectSnapshotWithEmptyMessages() {
        let params: [String: Any] = [
            "subscriptionId": "sub-chat",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                "agentId": "agent-123",
                "messages": [[String: Any]](),
                "truncated": false,
                "totalMessages": 0
            ]
        ]

        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push != nil)
        #expect(push?.snapshot?.isEmpty == true)
        #expect(push?.snapshotMeta?["agentId"] as? String == "agent-123")
    }

    @Test func parseDeltaPush() {
        let params: [String: Any] = [
            "subscriptionId": "sub-123",
            "kind": "delta",
            "seq": 1,
            "delta": [
                "added": [["id": "ws-3", "title": "New"]],
                "updated": [["id": "ws-1", "title": "Updated"]],
                "removedIds": ["ws-2"]
            ]
        ]

        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push != nil)
        #expect(push?.subscriptionId == "sub-123")
        #expect(push?.seq == 1)
        #expect(push?.delta?.added.count == 1)
        #expect(push?.delta?.updated.count == 1)
        #expect(push?.delta?.removedIds.count == 1)
        #expect(push?.delta?.chatBlocks == nil) // Collection entities are not block-shaped
    }

    @Test func parseNonPushMethodReturnsNil() {
        let params: [String: Any] = ["foo": "bar"]
        let push = SubscriptionPush.parse(method: "other.method", params: params)
        #expect(push == nil)
    }

    @Test func parseMalformedPushReturnsNil() {
        let params: [String: Any] = ["kind": "snapshot"] // missing subscriptionId and seq
        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push == nil)

        // Snapshot push missing "snapshot" field
        let snapshotMissingPayload: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0
        ]
        #expect(SubscriptionPush.parse(method: "subscription.push", params: snapshotMissingPayload) == nil)

        // Delta push missing "delta" field
        let deltaMissingPayload: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "delta",
            "seq": 1
        ]
        #expect(SubscriptionPush.parse(method: "subscription.push", params: deltaMissingPayload) == nil)

        // Snapshot object without a "messages" array is malformed
        let objectSnapshotNoMessages: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": ["agentId": "agent-123", "truncated": false]
        ]
        #expect(SubscriptionPush.parse(method: "subscription.push", params: objectSnapshotNoMessages) == nil)

        // Snapshot object whose "messages" is not an array is malformed
        let objectSnapshotBadMessages: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": ["agentId": "agent-123", "messages": "nope"]
        ]
        #expect(SubscriptionPush.parse(method: "subscription.push", params: objectSnapshotBadMessages) == nil)

        // Scalar snapshot is malformed
        let scalarSnapshot: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": 42
        ]
        #expect(SubscriptionPush.parse(method: "subscription.push", params: scalarSnapshot) == nil)
    }

    private func blockShapedDeltaParams() -> [String: Any] {
        [
            "subscriptionId": "sub-chat",
            "kind": "delta",
            "seq": 6,
            "delta": [
                "added": [
                    [
                        "agentId": "agent-123",
                        "messageId": "0190a200-asst",
                        "role": "assistant",
                        "block": ["type": "tool_use", "id": "0190a200-asst:1", "name": "view", "input": ["path": "a.txt"]]
                    ]
                ],
                "updated": [
                    [
                        "agentId": "agent-123",
                        "messageId": "0190a200-asst",
                        "role": "assistant",
                        "block": ["type": "text", "id": "0190a200-asst:0", "text": "Let me check the logs first."],
                        "messageSeq": 4,
                        "timestamp": "2026-06-27T01:00:10.000Z",
                        "streamingComplete": true
                    ]
                ],
                "removedIds": ["0190a200-asst:2"]
            ]
        ]
    }

    @Test func parseBlockShapedDeltaPassthrough() throws {
        let push = try #require(SubscriptionPush.parse(
            method: "subscription.push",
            params: blockShapedDeltaParams()
        ))
        #expect(push.kind == .delta)
        #expect(push.seq == 6)

        // Raw dictionaries pass through untouched so a block-level reducer can consume them
        let added = push.delta?.added.first
        #expect(added?["messageId"] as? String == "0190a200-asst")
        #expect(added?["role"] as? String == "assistant")
        let addedBlock = added?["block"] as? [String: Any]
        #expect(addedBlock?["id"] as? String == "0190a200-asst:1")
        #expect(addedBlock?["type"] as? String == "tool_use")

        let updated = push.delta?.updated.first
        #expect(updated?["messageSeq"] as? Int == 4)
        #expect(updated?["streamingComplete"] as? Bool == true)
        let updatedBlock = updated?["block"] as? [String: Any]
        #expect(updatedBlock?["id"] as? String == "0190a200-asst:0")
        #expect(updatedBlock?["text"] as? String == "Let me check the logs first.")

        #expect(push.delta?.removedIds == ["0190a200-asst:2"])

        // Block-shaped entities are also pre-decoded (added, then updated) so the
        // transcript merges typed blocks without a per-block decode on MainActor.
        let chatBlocks = try #require(push.delta?.chatBlocks)
        #expect(chatBlocks.count == 2)
        #expect(chatBlocks[0].messageId == "0190a200-asst")
        #expect(chatBlocks[0].role == .assistant)
        #expect(chatBlocks[0].block.id == "0190a200-asst:1")
        #expect(chatBlocks[0].block.type == .toolUse)
        #expect(chatBlocks[0].block.resolvedName == "view")
        #expect(chatBlocks[0].block.input["path"]?.stringValue == "a.txt")
        #expect(chatBlocks[0].timestamp == nil)
        #expect(chatBlocks[0].streamingComplete == false)
        #expect(chatBlocks[1].block.id == "0190a200-asst:0")
        #expect(chatBlocks[1].block.resolvedText == "Let me check the logs first.")
        #expect(chatBlocks[1].timestamp == "2026-06-27T01:00:10.000Z")
        #expect(chatBlocks[1].streamingComplete == true)
    }

    @Test func parseBlockShapedDeltaDropsEntitiesWithoutDecodableBlock() {
        let params: [String: Any] = [
            "subscriptionId": "sub-chat",
            "kind": "delta",
            "seq": 7,
            "delta": [
                "added": [
                    ["messageId": "m-1", "block": "not a block"],
                    ["block": ["type": "text", "id": "b-1", "text": "no messageId"]],
                    ["messageId": "m-1", "block": ["type": "text", "id": "b-2", "text": "ok"]]
                ],
                "updated": [[String: Any]](),
                "removedIds": [String]()
            ]
        ]

        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push?.delta?.added.count == 3)
        #expect(push?.delta?.chatBlocks?.map(\.block.id) == ["b-2"])
    }
}

extension DeltaSubscriptionTests {
    @Test func fragmentDecodePreservesTextSeparatelyOnBothDecodePaths() throws {
        let entities: [[String: Any]] = ["text", "thinking"].map { type in
            ["messageId": "message", "block": ["id": type, "type": type, "textDelta": " café 🦊"]]
        }
        let push = try #require(SubscriptionPush.parse(method: "subscription.push", params: [
            "subscriptionId": "chat", "kind": "delta", "seq": 1,
            "delta": ["added": entities, "updated": [], "removedIds": []]
        ]))
        let decoded = try #require(push.delta?.chatBlocks)
        #expect(decoded.count == 2)
        for (entity, block) in zip(entities, decoded) {
            let individual = try #require(SubscriptionPush.ChatBlockEntity(entity: entity))
            #expect(block.textDelta == " café 🦊")
            #expect(block.block.resolvedText == nil)
            #expect(individual.textDelta == block.textDelta)
            #expect(individual.block == block.block)
        }
    }

    @Test func fragmentDecodeRejectsInvalidFragmentIdentityAndTextWithoutAffectingFullBlocks() {
        let blocks: [[String: Any]] = [
            ["id": "valid", "type": "text", "textDelta": ""],
            ["id": "invalid-delta", "type": "text", "textDelta": 42],
            ["type": "thinking", "textDelta": "missing id"],
            ["id": "", "type": "text", "textDelta": "empty id"],
            ["id": "invalid-text", "type": "text", "text": 42, "textDelta": "fragment"],
            ["id": "full", "type": "text", "text": "authority", "textDelta": "ignored"],
            ["id": "resource", "type": "resource", "textDelta": "not a text fragment"]
        ]
        let entities = blocks.map { ["messageId": "message", "block": $0] as [String: Any] }
        let decoded = SubscriptionPush.ChatBlockEntity.decodeAll(entities)
        #expect(decoded.map(\.block.id) == ["valid", "full", "resource"])
        #expect(decoded.map(\.textDelta) == ["", nil, nil])
        #expect(decoded.map(\.block) == entities.compactMap { SubscriptionPush.ChatBlockEntity(entity: $0)?.block })
    }

    // MARK: - DeltaReconciler

    @Test func reconcilerSnapshot() {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )

        let items = [
            ["id": "1", "name": "One"],
            ["id": "2", "name": "Two"]
        ]
        reconciler.applySnapshot(seq: 0, rawItems: items)

        let values = reconciler.values()
        #expect(values.count == 2)
    }

    @Test func reconcilerDelta() {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )

        // Start with snapshot
        let snapshot = [
            ["id": "1", "name": "One"],
            ["id": "2", "name": "Two"]
        ]
        reconciler.applySnapshot(seq: 0, rawItems: snapshot)

        // Apply delta
        let delta = SubscriptionPush.DeltaPayload(
            added: [["id": "3", "name": "Three"]],
            updated: [["id": "1", "name": "One Updated"]],
            removedIds: ["2"]
        )
        let success = reconciler.applyDelta(seq: 1, delta: delta)

        #expect(success == true)
        let values = reconciler.values()
        #expect(values.count == 2) // 1 (updated) + 3 (added), 2 removed
    }

    @Test func reconcilerDeltaGapDetection() {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )

        // Start with snapshot
        reconciler.applySnapshot(seq: 0, rawItems: [["id": "1", "name": "One"]])

        // Try to apply delta with wrong seq (gap)
        let delta = SubscriptionPush.DeltaPayload(added: [["id": "2", "name": "Two"]], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 5, delta: delta) // Expected 1, got 5

        #expect(success == false)
    }

    @Test func reconcilerDeltaBeforeSnapshotFails() {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )

        // Try to apply delta without snapshot (not seeded)
        let delta = SubscriptionPush.DeltaPayload(added: [["id": "1", "name": "One"]], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 1, delta: delta)

        #expect(success == false)
    }

    @Test func reconcilerReset() {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )

        reconciler.applySnapshot(seq: 0, rawItems: [["id": "1", "name": "One"]])
        #expect(reconciler.values().count == 1)

        reconciler.reset()
        #expect(reconciler.values().isEmpty)

        // After reset, delta should fail (not seeded)
        let delta = SubscriptionPush.DeltaPayload(added: [["id": "2", "name": "Two"]], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        #expect(success == false)
    }
}
