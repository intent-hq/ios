@testable import Intent
import Testing

// MARK: - Row metadata on live entities (PROTOCOL 07 §7.1)

extension ConversationStoreLiveStateTests {
    private static let a2aText = "[MESSAGE FROM AGENT Coordinator (agent-1)]\n\nDo the thing"

    private func a2aEntity(metadata: [String: Any] = [:]) -> [String: Any] {
        var entity = blockEntity(
            messageId: "msg-a2a",
            block: ["type": "text", "id": "msg-a2a:0", "text": Self.a2aText],
            role: "user",
            streamingComplete: true
        )
        if !metadata.isEmpty { entity["metadata"] = metadata }
        return entity
    }

    @Test func liveUserRowAdoptsEntityMetadata() {
        let (store, _) = makeStore()
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            a2aEntity(metadata: [
                "type": "agent_message",
                "fromAgentId": "agent-1",
                "fromAgentName": "Coordinator"
            ])
        ]))

        #expect(store.messages.count == 1)
        #expect(store.messages[0].agentMessageAttribution?.fromAgentId == "agent-1")
        #expect(store.messages[0].agentMessageAttribution?.rawName == "Coordinator")
    }

    @Test func liveEntityWithoutMetadataKeepsAdoptedRowMetadata() {
        let (store, _) = makeStore()
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            a2aEntity(metadata: ["type": "agent_message", "fromAgentId": "agent-1"])
        ]))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            a2aEntity()
        ]))

        #expect(store.messages.count == 1)
        #expect(store.messages[0].agentMessageAttribution?.fromAgentId == "agent-1")
    }

    @Test func liveEventWakeRowAdoptsEntityMetadata() {
        let (store, _) = makeStore()
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        var entity = blockEntity(
            messageId: "msg-wake",
            block: ["type": "text", "id": "msg-wake:0", "text": "[WORKSPACE EVENTS] Child agent reported."],
            role: "user",
            streamingComplete: true
        )
        entity["metadata"] = [
            "type": "event_notification",
            "eventCount": 1,
            "eventTypes": ["agent:reportToParent"]
        ]
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [entity]))

        #expect(store.messages[0].eventWakeAttribution?.eventTypes == ["agent:reportToParent"])
    }
}
