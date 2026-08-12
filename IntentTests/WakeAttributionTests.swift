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
        let empty = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"), "hookName": AnyCodable("   "),
        ])
        #expect(empty?.displayName == "Hook")
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
