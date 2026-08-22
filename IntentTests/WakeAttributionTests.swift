import Foundation
import Testing
@testable import Intent

// MARK: - Hook wake attribution (PROTOCOL §5.40)

struct HookWakeAttributionTests {
    @Test func extractsFromValidMetadata() {
        let attribution = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"), "hookId": AnyCodable("h-1"),
            "hookName": AnyCodable("CI watcher"), "reason": AnyCodable("dispatched"),
        ])
        #expect(attribution == HookWakeAttribution(
            hookId: "h-1", rawName: "CI watcher", displayName: "CI watcher",
            reason: "dispatched", hookStillActive: nil))
    }

    @Test func nilWhenMetadataAbsentOrWrongType() {
        #expect(HookWakeAttribution.from(nil) == nil)
        #expect(HookWakeAttribution.from([:]) == nil)
        #expect(HookWakeAttribution.from(["type": AnyCodable("agent_message")]) == nil)
    }

    @Test func fallsBackToHookNameWhenAbsentOrEmpty() {
        let absent = HookWakeAttribution.from(["type": AnyCodable("hook_wake")])
        #expect(absent?.displayName == "Hook")
        let blank = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"), "hookName": AnyCodable("   "),
        ])
        #expect(blank?.displayName == "Hook")
        // rawName stays verbatim — the daemon used it as-is in the prefix.
        #expect(blank?.rawName == "   ")
    }

    @Test func keepsEdgeWhitespaceInRawNameWhileTrimmingDisplayName() {
        let attribution = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"),
            "hookName": AnyCodable(" my \"quoted\" hook "),
        ])
        #expect(attribution?.rawName == " my \"quoted\" hook ")
        #expect(attribution?.displayName == "my \"quoted\" hook")
    }

    @Test func truncatesLongNames() {
        let attribution = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"),
            "hookName": AnyCodable("A very long hook name that keeps going"),
        ])
        #expect(attribution?.displayName == "A very long hook na…")
        #expect(attribution?.displayName.count == 20)
        // rawName keeps the untruncated name for exact prefix stripping.
        #expect(attribution?.rawName == "A very long hook name that keeps going")
    }

    @Test func stateLabelVariants() {
        func make(reason: String, active: Bool? = nil) -> HookWakeAttribution {
            HookWakeAttribution(
                hookId: "h", rawName: "H", displayName: "H",
                reason: reason, hookStillActive: active)
        }
        #expect(make(reason: "evicted").stateLabel == "woke the agent and is now retired")
        #expect(make(reason: "evicted", active: true).stateLabel == "woke the agent and is now retired")
        #expect(make(reason: "dispatched", active: true).stateLabel == "woke the agent and will continue to run")
        #expect(make(reason: "dispatched", active: false).stateLabel == "woke the agent and is now retired")
        #expect(make(reason: "dispatched").stateLabel == "woke the agent")
        #expect(make(reason: "").stateLabel == "woke the agent")
    }

    private func attribution(named rawName: String) -> HookWakeAttribution {
        HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"), "hookName": AnyCodable(rawName),
        ])!
    }

    @Test func stripsPrefix() {
        #expect(HookWakeAttribution.stripPrefix("[Background hook \"CI\"] Build failed") == "Build failed")
        #expect(HookWakeAttribution.stripPrefix("No prefix here") == "No prefix here")
    }

    @Test func stripPrefixStripsQuotedHookNameWithMetadata() {
        // FE parity (hook-wake-attribution.ts, intent-hq/monorepo#2025): with
        // attribution metadata, the exact literal prefix built from the raw
        // name strips even when the name contains double quotes.
        let quoted = "[Background hook \"my \"quoted\" hook\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            quoted, attribution: attribution(named: "my \"quoted\" hook")) == "Build failed")
    }

    @Test func stripPrefixStripsEdgeWhitespaceAndQuotedName() {
        // The verbatim (untrimmed) rawName matches the daemon's literal
        // prefix even when the name carries edge whitespace.
        let text = "[Background hook \" my \"quoted\" hook \"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text, attribution: attribution(named: " my \"quoted\" hook ")) == "Build failed")
    }

    @Test func stripPrefixStripsWhitespaceOnlyName() {
        // A whitespace-only name falls back to "Hook" for display but the
        // daemon still used it verbatim in the prefix.
        let text = "[Background hook \"   \"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text, attribution: attribution(named: "   ")) == "Build failed")
    }

    @Test func stripPrefixWithoutMetadataLeavesQuotedHookNameUnstripped() {
        // Regex fallback (no metadata): `"[^"]*"` stops at the embedded
        // quote, so the prefix is left in place on both clients.
        let quoted = "[Background hook \"my \"quoted\" hook\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(quoted) == quoted)
    }

    @Test func stripPrefixFallsBackToRegexOnNameMismatch() {
        // Metadata name not matching the text prefix (e.g. an older message
        // from a renamed hook) falls back to the regex strip.
        let text = "[Background hook \"old name\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text, attribution: attribution(named: "new name")) == "Build failed")
    }

    @Test func stripPrefixUsesUntruncatedRawName() {
        // Names past the ~20-char display truncation still strip via rawName.
        let text = "[Background hook \"A very long hook name that keeps going\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text,
            attribution: attribution(named: "A very long hook name that keeps going")) == "Build failed")
    }

    @Test func stripPrefixToleratesTrailingWhitespaceAfterLiteral() {
        // The literal strip consumes trailing whitespace like the regex's \s*.
        let name = "my \"quoted\" hook"
        let md = attribution(named: name)
        #expect(HookWakeAttribution.stripPrefix(
            "[Background hook \"\(name)\"]\n\nBuild failed", attribution: md) == "Build failed")
        #expect(HookWakeAttribution.stripPrefix(
            "[Background hook \"\(name)\"]Build failed", attribution: md) == "Build failed")
    }

    @Test func stripsTrailingStateNote() {
        let text = "Build failed\n\n[This hook has now been retired.]"
        #expect(HookWakeAttribution.stripStateNote(text) == "Build failed")
        // Note constituting the whole string (empty dispatch message).
        #expect(HookWakeAttribution.stripStateNote("[This hook will continue to run.]") == "")
        // Notes embedded mid-text are left alone.
        let embedded = "[This hook fired.] and more text"
        #expect(HookWakeAttribution.stripStateNote(embedded) == embedded)
    }

    @Test func displayTextStripsPrefixAndNote() {
        let text = "[Background hook \"CI\"] Build failed\n\n[This hook has now been retired.]"
        #expect(HookWakeAttribution.displayText(text) == "Build failed")
        // Metadata-first path: quoted names strip end-to-end too.
        let quoted = "[Background hook \"my \"quoted\" hook\"] Build failed\n\n[This hook has now been retired.]"
        #expect(HookWakeAttribution.displayText(
            quoted, attribution: attribution(named: "my \"quoted\" hook")) == "Build failed")
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        let meta: [String: AnyCodable] = [
            "type": AnyCodable("hook_wake"), "hookName": AnyCodable("CI"),
        ]
        let fromRow = ConversationMessage(
            id: "m1", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z", metadata: meta)
        #expect(fromRow.hookWakeAttribution?.displayName == "CI")

        let fromBlock = ConversationMessage(
            id: "m2", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta)],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(fromBlock.hookWakeAttribution?.displayName == "CI")

        let plain = ConversationMessage(
            id: "m3", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(plain.hookWakeAttribution == nil)
    }
}

// MARK: - PR-monitor wake attribution (PROTOCOL §5.42)

struct PrMonitorWakeAttributionTests {
    private func meta(_ extra: [String: AnyCodable] = [:]) -> [String: AnyCodable] {
        var md: [String: AnyCodable] = [
            "type": AnyCodable("pr_monitor_wake"), "monitorId": AnyCodable("m-1"),
            "repo": AnyCodable("intent-hq/intentd"), "prNumber": AnyCodable(512),
        ]
        for (k, v) in extra { md[k] = v }
        return md
    }

    @Test func extractsFromValidMetadata() {
        let attribution = PrMonitorWakeAttribution.from(meta(["url": AnyCodable("https://example.com/pr")]))
        #expect(attribution == PrMonitorWakeAttribution(
            monitorId: "m-1", repo: "intent-hq/intentd", prNumber: 512,
            url: "https://example.com/pr"))
    }

    @Test func nilWhenMetadataAbsentMalformedOrWrongType() {
        #expect(PrMonitorWakeAttribution.from(nil) == nil)
        #expect(PrMonitorWakeAttribution.from(["type": AnyCodable("hook_wake")]) == nil)
        // repo and a positive integer prNumber are both required.
        #expect(PrMonitorWakeAttribution.from(meta(["repo": AnyCodable("  ")])) == nil)
        #expect(PrMonitorWakeAttribution.from(meta(["prNumber": AnyCodable(0)])) == nil)
        #expect(PrMonitorWakeAttribution.from(meta(["prNumber": AnyCodable("512")])) == nil)
    }

    @Test func resolvedUrlFallsBackToGitHub() {
        let attribution = PrMonitorWakeAttribution.from(meta())
        #expect(attribution?.url == nil)
        #expect(attribution?.resolvedUrl == "https://github.com/intent-hq/intentd/pull/512")
        let withUrl = PrMonitorWakeAttribution.from(meta(["url": AnyCodable("https://example.com/pr")]))
        #expect(withUrl?.resolvedUrl == "https://example.com/pr")
        // Blank url is treated as absent.
        let blankUrl = PrMonitorWakeAttribution.from(meta(["url": AnyCodable("  ")]))
        #expect(blankUrl?.url == nil)
    }

    @Test func chipLabelFollowsMonitoredPrsRowConvention() {
        let attribution = PrMonitorWakeAttribution.from(meta())!
        #expect(attribution.chipLabel(workspaceRepo: "intent-hq/intentd") == "#512")
        #expect(attribution.chipLabel(workspaceRepo: "intent-hq/monorepo") == "intent-hq/intentd: #512")
        #expect(attribution.chipLabel(workspaceRepo: nil) == "#512")
    }

    @Test func stripsPrefix() {
        #expect(PrMonitorWakeAttribution.stripPrefix("[PR monitor intent-hq/intentd#512] Checks failed") == "Checks failed")
        #expect(PrMonitorWakeAttribution.stripPrefix("No prefix") == "No prefix")
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        // Conflicting block metadata proves the row is checked first.
        let fromRow = ConversationMessage(
            id: "m1", role: .user,
            contentBlocks: [ContentBlock(
                type: .text, text: "x",
                messageMetadata: meta(["prNumber": AnyCodable(999)]))],
            timestamp: "2025-01-01T00:00:00Z", metadata: meta())
        #expect(fromRow.prMonitorWakeAttribution?.prNumber == 512)

        let fromBlock = ConversationMessage(
            id: "m2", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta())],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(fromBlock.prMonitorWakeAttribution?.prNumber == 512)

        let plain = ConversationMessage(
            id: "m3", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(plain.prMonitorWakeAttribution == nil)
    }
}

// MARK: - Event-notification wake attribution (agent wakes)

struct EventWakeAttributionTests {
    @Test func extractsFromValidMetadata() {
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable(2),
            "eventTypes": AnyCodable(["agent:idle", "file:changed"]),
            "events": AnyCodable([
                ["type": "agent:idle", "data": ["agentName": "Verifier"],
                 "timestamp": "2025-01-01T00:00:00Z"],
                ["type": "file:changed", "data": [String: Any]()],
            ] as [[String: Any]]),
        ])
        #expect(attribution == EventWakeAttribution(
            eventCount: 2,
            eventTypes: ["agent:idle", "file:changed"],
            events: [
                EventWakeAttribution.Event(type: "agent:idle", agentName: "Verifier"),
                EventWakeAttribution.Event(type: "file:changed", agentName: nil),
            ]))
    }

    @Test func nilWhenMetadataAbsentOrWrongType() {
        #expect(EventWakeAttribution.from(nil) == nil)
        #expect(EventWakeAttribution.from([:]) == nil)
        #expect(EventWakeAttribution.from(["type": AnyCodable("hook_wake")]) == nil)
    }

    @Test func toleratesMalformedFields() {
        // Wrong-typed count/types/events degrade to empty, never crash.
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable("two"),
            "eventTypes": AnyCodable([1, true] as [Any]),
            "events": AnyCodable(["not-a-dict", ["data": ["agentId": "x"]]] as [Any]),
        ])
        #expect(attribution == EventWakeAttribution(
            eventCount: 0, eventTypes: [], events: []))
        #expect(attribution?.summaryLabel == "Subscription update")
    }

    @Test func countFallsBackToEventsThenTypes() {
        let fromEvents = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([["type": "agent:idle"]]),
        ])
        #expect(fromEvents?.eventCount == 1)
        let fromTypes = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventTypes": AnyCodable(["file:changed", "task:updated"]),
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
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: json.data(using: .utf8)!)
        #expect(msg.eventWakeAttribution == EventWakeAttribution(
            eventCount: 1,
            eventTypes: ["agent:idle"],
            events: [EventWakeAttribution.Event(type: "agent:idle", agentName: "Verifier")]))
    }

    @Test func dropsIdShapedAgentNames() {
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([
                ["type": "agent:idle",
                 "data": ["agentName": "agent-01234567-89ab-cdef-0123-456789abcdef"]],
                ["type": "agent:idle", "data": ["name": "Implementor"]],
            ] as [[String: Any]]),
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
                ["type": "file:created"],
            ] as [[String: Any]]),
        ])
        // Category labels dedupe (both file:* events collapse into one).
        #expect(attribution?.summaryLabel == "Verifier finished, File changes")
    }

    @Test func summaryLabelFallsBackToTypesAndCountsLargeBursts() {
        let fromTypes = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventTypes": AnyCodable(["agent:idle", "task:updated"]),
        ])
        #expect(fromTypes?.summaryLabel == "Agent finished, Task updates")
        let burst = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventCount": AnyCodable(7),
            "eventTypes": AnyCodable(["file:changed"]),
        ])
        #expect(burst?.summaryLabel == "7 events")
    }

    @Test func unknownTypesAreHumanized() {
        // Machine identifiers never surface verbatim in the banner.
        let attribution = EventWakeAttribution.from([
            "type": AnyCodable("event_notification"),
            "eventTypes": AnyCodable(["custom:thing", "agent:status-changed"]),
        ])
        #expect(attribution?.summaryLabel == "Custom thing, Agent status changed")
    }

    @Test func legacyPrefixRowsFallBackToEmptyAttribution() {
        // Metadata-less legacy rows still render the banner off the text
        // prefix (FE parity: isEventWakeMessage) instead of raw machine text.
        let legacy = ConversationMessage(
            id: "m4", role: .user,
            contentBlocks: [ContentBlock(
                type: .text, text: "[WORKSPACE EVENTS] 1. [agent:idle] Verifier went idle")],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(legacy.eventWakeAttribution == EventWakeAttribution(
            eventCount: 0, eventTypes: [], events: []))
        #expect(legacy.eventWakeAttribution?.summaryLabel == "Subscription update")

        let ordinary = ConversationMessage(
            id: "m5", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "hello")],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(ordinary.eventWakeAttribution == nil)
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        let meta: [String: AnyCodable] = [
            "type": AnyCodable("event_notification"), "eventCount": AnyCodable(1),
        ]
        let fromRow = ConversationMessage(
            id: "m1", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z", metadata: meta)
        #expect(fromRow.eventWakeAttribution?.eventCount == 1)

        let fromBlock = ConversationMessage(
            id: "m2", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta)],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(fromBlock.eventWakeAttribution?.eventCount == 1)

        let plain = ConversationMessage(
            id: "m3", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(plain.eventWakeAttribution == nil)
    }
}


// MARK: - Agent-to-agent message attribution

struct AgentMessageAttributionTests {
    @Test func extractsFromValidMetadata() {
        let attribution = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("agent-1"),
            "fromAgentName": AnyCodable("Coordinator"),
        ])
        #expect(attribution == AgentMessageAttribution(
            fromAgentId: "agent-1", displayName: "Coordinator"))
    }

    @Test func nilWhenMetadataAbsentOrWrongType() {
        #expect(AgentMessageAttribution.from(nil) == nil)
        #expect(AgentMessageAttribution.from([:]) == nil)
        #expect(AgentMessageAttribution.from([
            "type": AnyCodable("hook_wake"), "fromAgentId": AnyCodable("agent-1"),
        ]) == nil)
    }

    @Test func nilWhenFromAgentIdMissingOrBlank() {
        #expect(AgentMessageAttribution.from(["type": AnyCodable("agent_message")]) == nil)
        #expect(AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("   "),
        ]) == nil)
    }

    @Test func fallsBackToAgentNameWhenAbsentOrBlank() {
        let absent = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-1"),
        ])
        #expect(absent?.displayName == "Agent")
        let blank = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-1"),
            "fromAgentName": AnyCodable("   "),
        ])
        #expect(blank?.displayName == "Agent")
    }

    @Test func trimsAndTruncatesLongNames() {
        let attribution = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable(" agent-1 "),
            "fromAgentName": AnyCodable(" A very long agent name that keeps going "),
        ])
        #expect(attribution?.fromAgentId == "agent-1")
        #expect(attribution?.displayName == "A very long agent n…")
        #expect(attribution?.displayName.count == 20)
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        let meta: [String: AnyCodable] = [
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-1"),
        ]
        let fromRow = ConversationMessage(
            id: "m1", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z", metadata: meta)
        #expect(fromRow.agentMessageAttribution?.fromAgentId == "agent-1")

        let fromBlock = ConversationMessage(
            id: "m2", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta)],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(fromBlock.agentMessageAttribution?.fromAgentId == "agent-1")

        let plain = ConversationMessage(
            id: "m3", role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z")
        #expect(plain.agentMessageAttribution == nil)
    }
}
