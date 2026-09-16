import Foundation
@testable import Intent
import Testing

// MARK: - Event-notification wake attribution (agent wakes)

struct EventWakeAttributionTests {
    @Test func extractsFromValidMetadata() {
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable(2),
            "eventTypes": AnyCodable(["agent:idle", "file:changed"]),
            "events": AnyCodable([
                [
                    "type": "agent:idle",
                    "data": ["agentName": "Verifier"],
                    "timestamp": "2025-01-01T00:00:00Z"
                ],
                ["type": "file:changed", "data": [String: Any]()]
            ] as [[String: Any]])
        ])
        #expect(attribution == EventWakeAttribution(
            eventCount: 2,
            eventTypes: ["agent:idle", "file:changed"],
            events: [
                EventWakeAttribution.Event(type: "agent:idle", agentName: "Verifier"),
                EventWakeAttribution.Event(type: "file:changed", agentName: nil)
            ]
        ))
    }

    @Test func nilWhenMetadataAbsentOrWrongType() {
        let message = ConversationMessage(
            id: "m-absent",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(!message.hasReportedMetadata)
        #expect(message.eventWakeAttribution == nil)
        #expect(EventWakeAttribution.from([:]) == nil)
        #expect(EventWakeAttribution.from(["type": AnyCodable("hook_wake")]) == nil)
    }

    @Test func toleratesMalformedFields() {
        // Wrong-typed count/types/events degrade to empty, never crash.
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable("two"),
            "eventTypes": AnyCodable([1, true] as [Any]),
            "events": AnyCodable(["not-a-dict", ["data": ["agentId": "x"]]] as [Any])
        ])
        #expect(attribution == EventWakeAttribution(
            eventCount: 0,
            eventTypes: [],
            events: []
        ))
        #expect(attribution?.summaryLabel == "Subscription update")
    }

    @Test func countFallsBackToEventsThenTypes() {
        let fromEvents = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([["type": "agent:idle"]])
        ])
        #expect(fromEvents?.eventCount == 1)
        let fromTypes = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventTypes": AnyCodable(["file:changed", "task:updated"])
        ])
        #expect(fromTypes?.eventCount == 2)
    }

    @Test func extractsFromDecodedWireMetadata() throws {
        // Wire-shaped JSON round-trip: nested events decode via AnyCodable.
        let json = """
        {"id":"m1","role":"user","timestamp":"2025-01-01T00:00:00Z",
         "contentBlocks":[{"type":"text","text":"[WORKSPACE EVENTS] machine text"}],
         "metadata":{"type":"event_notification","eventCount":1,
          "eventTypes":["agent:idle"],
          "events":[{"type":"agent:idle","data":{"agentName":"Verifier"},
                     "timestamp":"2025-01-01T00:00:00Z"}]}}
        """
        let data = try #require(json.data(using: .utf8))
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: data)
        #expect(msg.eventWakeAttribution == EventWakeAttribution(
            eventCount: 1,
            eventTypes: ["agent:idle"],
            events: [EventWakeAttribution.Event(type: "agent:idle", agentName: "Verifier")]
        ))
    }

    @Test func dropsIdShapedAgentNames() {
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([
                [
                    "type": "agent:idle",
                    "data": ["agentName": "agent-01234567-89ab-cdef-0123-456789abcdef"]
                ],
                ["type": "agent:idle", "data": ["name": "Implementor"]]
            ] as [[String: Any]])
        ])
        #expect(attribution?.events[0].agentName == nil)
        #expect(attribution?.events[1].agentName == "Implementor")
    }

    @Test func summaryLabelListsSmallWakes() {
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable(3),
            "events": AnyCodable([
                ["type": "agent:idle", "data": ["agentName": "Verifier"]],
                ["type": "file:changed"],
                ["type": "file:created"]
            ] as [[String: Any]])
        ])
        // Category labels dedupe (both file:* events collapse into one).
        #expect(attribution?.summaryLabel == "Verifier finished, File changes")
    }

    @Test func summaryLabelFallsBackToTypesAndCountsLargeBursts() {
        let fromTypes = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventTypes": AnyCodable(["agent:idle", "task:updated"])
        ])
        #expect(fromTypes?.summaryLabel == "Agent finished, Task updates")
        let burst = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable(7),
            "eventTypes": AnyCodable(["file:changed"])
        ])
        #expect(burst?.summaryLabel == "7 events")
    }

    @Test func unknownTypesAreHumanized() {
        // Machine identifiers never surface verbatim in the banner.
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventTypes": AnyCodable(["custom:thing", "agent:status-changed"])
        ])
        #expect(attribution?.summaryLabel == "Custom thing, Agent status changed")
    }

    @Test func legacyPrefixRowsFallBackToEmptyAttribution() {
        // Metadata-less legacy rows still render the banner off the text
        // prefix (FE parity: isEventWakeMessage) instead of raw machine text.
        let legacy = ConversationMessage(
            id: "m4",
            role: .user,
            contentBlocks: [
                ContentBlock(
                    type: .text,
                    text: "[WORKSPACE EVENTS] 1. [agent:idle] Verifier went idle"
                )
            ],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(legacy.eventWakeAttribution == EventWakeAttribution(
            eventCount: 0,
            eventTypes: [],
            events: []
        ))
        #expect(legacy.eventWakeAttribution?.summaryLabel == "Subscription update")

        let ordinary = ConversationMessage(
            id: "m5",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "hello")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(ordinary.eventWakeAttribution == nil)
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        let meta: [String: AnyCodable] = [
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable(1)
        ]
        let fromRow = ConversationMessage(
            id: "m1",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z",
            metadata: meta
        )
        #expect(fromRow.eventWakeAttribution?.eventCount == 1)

        let fromBlock = ConversationMessage(
            id: "m2",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta)],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(fromBlock.eventWakeAttribution?.eventCount == 1)

        let plain = ConversationMessage(
            id: "m3",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(plain.eventWakeAttribution == nil)
    }
}
