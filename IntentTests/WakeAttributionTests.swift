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
}

// MARK: - Agent-to-agent message attribution

struct AgentMessageAttributionTests {
    @Test func extractsFromValidMetadata() {
        let attribution = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("agent-2"),
            "fromAgentName": AnyCodable("Verifier"),
        ])
        #expect(attribution == AgentMessageAttribution(
            fromAgentId: "agent-2", displayName: "Verifier"))
    }

    @Test func nilWhenMetadataAbsentMalformedOrWrongType() {
        #expect(AgentMessageAttribution.from(nil) == nil)
        #expect(AgentMessageAttribution.from([:]) == nil)
        #expect(AgentMessageAttribution.from(["type": AnyCodable("hook_wake")]) == nil)
        // fromAgentId is required and must be non-empty.
        #expect(AgentMessageAttribution.from(["type": AnyCodable("agent_message")]) == nil)
        #expect(AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("   "),
        ]) == nil)
    }

    @Test func fallsBackToAgentNameWhenAbsentOrBlank() {
        let absent = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-2"),
        ])
        #expect(absent?.displayName == "Agent")
        let blank = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-2"),
            "fromAgentName": AnyCodable("   "),
        ])
        #expect(blank?.displayName == "Agent")
    }

    @Test func truncatesLongNames() {
        let attribution = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-2"),
            "fromAgentName": AnyCodable("A very long agent name that keeps going"),
        ])
        #expect(attribution?.displayName == "A very long agent n…")
        #expect(attribution?.displayName.count == 20)
    }
}

// MARK: - Event-notification wake summary

struct EventWakeSummaryTests {
    private func structuredEvent(
        type: String, agentId: String, agentName: String? = nil,
        completionReport: String? = nil, lastResponseSummary: String? = nil
    ) -> [String: Any] {
        var data: [String: Any] = ["agentId": agentId]
        if let agentName { data["agentName"] = agentName }
        if let completionReport { data["completionReport"] = completionReport }
        if let lastResponseSummary { data["lastResponseSummary"] = lastResponseSummary }
        return ["type": type, "data": data, "timestamp": "2025-01-01T00:00:00Z"]
    }

    @Test func detectsEventNotificationMetadataFirstWithContentFallback() {
        #expect(EventWake.isEventNotification(
            content: "anything", metadata: ["type": AnyCodable("event_notification")]))
        #expect(EventWake.isEventNotification(content: "[WORKSPACE EVENTS] 1 event", metadata: nil))
        #expect(EventWake.isEventNotification(
            content: "[WORKSPACE EVENTS] 1 event",
            metadata: ["userAppMessageId": AnyCodable("uam-1")]))
        #expect(!EventWake.isEventNotification(content: "plain message", metadata: nil))
        #expect(!EventWake.isEventNotification(
            content: "plain", metadata: ["type": AnyCodable("agent_message")]))
        // A typed non-event entry does not fall back on the content prefix:
        // an agent_message quoting "[WORKSPACE EVENTS]" stays an agent message.
        #expect(!EventWake.isEventNotification(
            content: "[WORKSPACE EVENTS] forwarded text",
            metadata: ["type": AnyCodable("agent_message"), "fromAgentId": AnyCodable("agent-2")]))
    }

    @Test func labelsSingleChildCompletionWithReportPreview() {
        let summary = EventWake.summarize(content: "", metadata: [
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([
                structuredEvent(type: "agent:idle", agentId: "agent-1", agentName: "Builder",
                                completionReport: "All tests pass"),
            ]),
        ])
        #expect(summary.label == "Child agent Builder completed")
        #expect(summary.preview == "All tests pass")
    }

    @Test func fallsBackToLegacyReportKeyForCompletionReport() {
        var event = structuredEvent(type: "agent:idle", agentId: "agent-1", agentName: "Builder")
        var data = event["data"] as! [String: Any]
        data["report"] = "Legacy report text"
        event["data"] = data
        let summary = EventWake.summarize(content: "", metadata: [
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([event]),
        ])
        #expect(summary.preview == "Legacy report text")

        // An empty completionReport also falls through to the report key.
        data["completionReport"] = "   "
        event["data"] = data
        let events = EventWake.parseAgentEvents(content: "", metadata: [
            "events": AnyCodable([event]),
        ])
        #expect(events.count == 1)
        #expect(events[0].completionReport == "Legacy report text")
    }

    @Test func joinsAgentLabelsBeforeCategoryLabels() {
        let summary = EventWake.summarize(content: "", metadata: [
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([
                structuredEvent(type: "agent:idle", agentId: "agent-1", agentName: "Builder"),
            ]),
            "eventTypes": AnyCodable(["agent:idle", "file:changed"]),
        ])
        #expect(summary.label == "Child agent Builder completed · file changes")
    }

    @Test func countsMultipleCompletionsAndCreations() {
        let summary = EventWake.summarize(content: "", metadata: [
            "type": AnyCodable("event_notification"),
            "events": AnyCodable([
                structuredEvent(type: "agent:idle", agentId: "agent-1"),
                structuredEvent(type: "agent:reportToParent", agentId: "agent-2"),
                structuredEvent(type: "agent:created", agentId: "agent-3", agentName: "New"),
            ]),
        ])
        #expect(summary.label == "2 child agents completed · Child agent New created")
        #expect(summary.preview == nil)
    }

    @Test func dedupesEventsByAgentIdLaterOverridesEarlier() {
        let events = EventWake.parseAgentEvents(content: "", metadata: [
            "events": AnyCodable([
                structuredEvent(type: "agent:created", agentId: "agent-1", agentName: "A"),
                structuredEvent(type: "agent:idle", agentId: "agent-1", agentName: "A",
                                lastResponseSummary: "Done"),
            ]),
        ])
        #expect(events.count == 1)
        #expect(events[0].type == "agent:idle")
        #expect(events[0].lastResponseSummary == "Done")
    }

    @Test func categorizesNonAgentEventTypes() {
        let summary = EventWake.summarize(content: "", metadata: [
            "type": AnyCodable("event_notification"),
            "eventTypes": AnyCodable(["file:changed", "task:updated"]),
            "eventCount": AnyCodable(3),
        ])
        #expect(summary.label == "file changes · task updates")
        #expect(summary.preview == nil)
    }

    @Test func fallsBackToEventCountLabel() {
        let one = EventWake.summarize(content: "", metadata: [
            "type": AnyCodable("event_notification"), "eventCount": AnyCodable(1),
        ])
        #expect(one.label == "1 workspace event")
        let many = EventWake.summarize(content: "", metadata: [
            "type": AnyCodable("event_notification"), "eventCount": AnyCodable(4),
        ])
        #expect(many.label == "4 workspace events")
        let none = EventWake.summarize(content: "", metadata: nil)
        #expect(none.label == "Workspace events")
    }

    @Test func parsesLegacyNumberedTextLines() {
        let content = """
        [WORKSPACE EVENTS] You have been woken up by 2 workspace events:
        1. [agent:idle] Agent "Builder" finished {{agentId:agent-1}}
        2. [file:changed] src/main.rs changed
        """
        let summary = EventWake.summarize(content: content, metadata: nil)
        #expect(summary.label == "Child agent Builder completed")
        // A named-agent label means no first-event-line preview.
        #expect(summary.preview == nil)

        let events = EventWake.parseAgentEvents(content: content, metadata: nil)
        #expect(events == [EventWake.ParsedAgentEvent(
            type: "agent:idle", agentId: "agent-1", agentName: "Builder",
            completionReport: nil, lastResponseSummary: nil)])
    }

    @Test func parsesLegacyParentheticalAgentId() {
        let content = "1. [agent:created] New agent \"Helper\" (agent-abc123) started"
        let events = EventWake.parseAgentEvents(content: content, metadata: nil)
        #expect(events.count == 1)
        #expect(events[0].agentId == "agent-abc123")
        #expect(events[0].agentName == "Helper")
    }

    @Test func legacyWakeWithoutAgentEventsGetsFirstEventLinePreview() {
        let content = """
        [WORKSPACE EVENTS] You have been woken up by 1 workspace event:
        1. [file:changed] src/main.rs changed
        """
        let summary = EventWake.summarize(content: content, metadata: nil)
        #expect(summary.label == "1 workspace event")
        #expect(summary.preview == "[file:changed] src/main.rs changed")
    }

    @Test func rustDaemonSingleLineWakeStripsPrefixForPreview() {
        let summary = EventWake.summarize(
            content: "[WORKSPACE EVENTS] 3 file events on src/", metadata: nil)
        #expect(summary.label == "Workspace events")
        #expect(summary.preview == "3 file events on src/")
    }

    @Test func genericWakeHeaderBoilerplateIsSkippedAsPreview() {
        let summary = EventWake.summarize(
            content: "[WORKSPACE EVENTS] You have been woken up by workspace activity",
            metadata: nil)
        #expect(summary.label == "Workspace events")
        #expect(summary.preview == nil)
    }

    @Test func longPreviewsAreTruncated() {
        let long = String(repeating: "x", count: 200)
        let summary = EventWake.summarize(
            content: "[WORKSPACE EVENTS] \(long)", metadata: nil)
        #expect(summary.preview?.count == 120)
        #expect(summary.preview?.hasSuffix("…") == true)
    }
}
