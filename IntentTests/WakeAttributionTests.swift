import Foundation
@testable import Intent
import Testing

// MARK: - Hook wake attribution (PROTOCOL §5.40)

struct HookWakeAttributionTests {
    @Test func extractsFromValidMetadata() {
        let attribution = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"),
            "hookId": AnyCodable("h-1"),
            "hookName": AnyCodable("CI watcher"),
            "reason": AnyCodable("dispatched")
        ])
        #expect(attribution == HookWakeAttribution(
            hookId: "h-1",
            rawName: "CI watcher",
            displayName: "CI watcher",
            reason: "dispatched",
            postWakeState: .unreported
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
        #expect(message.hookWakeAttribution == nil)
        #expect(HookWakeAttribution.from([:]) == nil)
        #expect(HookWakeAttribution.from(["type": AnyCodable("agent_message")]) == nil)
    }

    @Test func fallsBackToHookNameWhenAbsentOrEmpty() {
        let absent = HookWakeAttribution.from(["type": AnyCodable("hook_wake")])
        #expect(absent?.displayName == "Hook")
        let blank = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"),
            "hookName": AnyCodable("   ")
        ])
        #expect(blank?.displayName == "Hook")
        // rawName stays verbatim — the daemon used it as-is in the prefix.
        #expect(blank?.rawName == "   ")
    }

    @Test func keepsEdgeWhitespaceInRawNameWhileTrimmingDisplayName() {
        let attribution = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"),
            "hookName": AnyCodable(" my \"quoted\" hook ")
        ])
        #expect(attribution?.rawName == " my \"quoted\" hook ")
        #expect(attribution?.displayName == "my \"quoted\" hook")
    }

    @Test func truncatesLongNames() {
        let attribution = HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"),
            "hookName": AnyCodable("A very long hook name that keeps going")
        ])
        #expect(attribution?.displayName == "A very long hook na…")
        #expect(attribution?.displayName.count == 20)
        // rawName keeps the untruncated name for exact prefix stripping.
        #expect(attribution?.rawName == "A very long hook name that keeps going")
    }

    @Test func stateLabelVariants() {
        func make(reason: String, state: HookPostWakeState = .unreported) -> HookWakeAttribution {
            HookWakeAttribution(
                hookId: "h",
                rawName: "H",
                displayName: "H",
                reason: reason,
                postWakeState: state
            )
        }
        #expect(make(reason: "evicted").stateLabel == "woke the agent and is now retired")
        #expect(make(reason: "evicted", state: .continues).stateLabel == "woke the agent and is now retired")
        #expect(make(reason: "dispatched", state: .continues).stateLabel == "woke the agent and will continue to run")
        #expect(make(reason: "dispatched", state: .retired).stateLabel == "woke the agent and is now retired")
        #expect(make(reason: "dispatched").stateLabel == "woke the agent")
        #expect(make(reason: "").stateLabel == "woke the agent")
    }

    private func attribution(named rawName: String) throws -> HookWakeAttribution {
        try #require(HookWakeAttribution.from([
            "type": AnyCodable("hook_wake"),
            "hookName": AnyCodable(rawName)
        ]))
    }

    @Test func stripsPrefix() {
        #expect(HookWakeAttribution.stripPrefix("[Background hook \"CI\"] Build failed") == "Build failed")
        #expect(HookWakeAttribution.stripPrefix("No prefix here") == "No prefix here")
    }

    @Test func stripPrefixStripsQuotedHookNameWithMetadata() throws {
        // FE parity (hook-wake-attribution.ts, intent-hq/monorepo#2025): with
        // attribution metadata, the exact literal prefix built from the raw
        // name strips even when the name contains double quotes.
        let quoted = "[Background hook \"my \"quoted\" hook\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            quoted,
            attribution: try attribution(named: "my \"quoted\" hook")
        ) == "Build failed")
    }

    @Test func stripPrefixStripsEdgeWhitespaceAndQuotedName() throws {
        // The verbatim (untrimmed) rawName matches the daemon's literal
        // prefix even when the name carries edge whitespace.
        let text = "[Background hook \" my \"quoted\" hook \"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text,
            attribution: try attribution(named: " my \"quoted\" hook ")
        ) == "Build failed")
    }

    @Test func stripPrefixStripsWhitespaceOnlyName() throws {
        // A whitespace-only name falls back to "Hook" for display but the
        // daemon still used it verbatim in the prefix.
        let text = "[Background hook \"   \"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text,
            attribution: try attribution(named: "   ")
        ) == "Build failed")
    }

    @Test func stripPrefixWithoutMetadataLeavesQuotedHookNameUnstripped() {
        // Regex fallback (no metadata): `"[^"]*"` stops at the embedded
        // quote, so the prefix is left in place on both clients.
        let quoted = "[Background hook \"my \"quoted\" hook\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(quoted) == quoted)
    }

    @Test func stripPrefixFallsBackToRegexOnNameMismatch() throws {
        // Metadata name not matching the text prefix (e.g. an older message
        // from a renamed hook) falls back to the regex strip.
        let text = "[Background hook \"old name\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text,
            attribution: try attribution(named: "new name")
        ) == "Build failed")
    }

    @Test func stripPrefixUsesUntruncatedRawName() throws {
        // Names past the ~20-char display truncation still strip via rawName.
        let text = "[Background hook \"A very long hook name that keeps going\"] Build failed"
        #expect(HookWakeAttribution.stripPrefix(
            text,
            attribution: try attribution(named: "A very long hook name that keeps going")
        ) == "Build failed")
    }

    @Test func stripPrefixToleratesTrailingWhitespaceAfterLiteral() throws {
        // The literal strip consumes trailing whitespace like the regex's \s*.
        let name = "my \"quoted\" hook"
        let metadata = try attribution(named: name)
        #expect(HookWakeAttribution.stripPrefix(
            "[Background hook \"\(name)\"]\n\nBuild failed",
            attribution: metadata
        ) == "Build failed")
        #expect(HookWakeAttribution.stripPrefix(
            "[Background hook \"\(name)\"]Build failed",
            attribution: metadata
        ) == "Build failed")
    }

    @Test func stripsTrailingStateNote() {
        let text = "Build failed\n\n[This hook has now been retired.]"
        #expect(HookWakeAttribution.stripStateNote(text) == "Build failed")
        // Note constituting the whole string (empty dispatch message).
        #expect(HookWakeAttribution.stripStateNote("[This hook will continue to run.]").isEmpty)
        // Notes embedded mid-text are left alone.
        let embedded = "[This hook fired.] and more text"
        #expect(HookWakeAttribution.stripStateNote(embedded) == embedded)
    }

    @Test func displayTextStripsPrefixAndNote() throws {
        let text = "[Background hook \"CI\"] Build failed\n\n[This hook has now been retired.]"
        #expect(HookWakeAttribution.displayText(text) == "Build failed")
        // Metadata-first path: quoted names strip end-to-end too.
        let quoted = "[Background hook \"my \"quoted\" hook\"] Build failed\n\n[This hook has now been retired.]"
        #expect(HookWakeAttribution.displayText(
            quoted,
            attribution: try attribution(named: "my \"quoted\" hook")
        ) == "Build failed")
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        let meta: [String: AnyCodable] = [
            "type": AnyCodable("hook_wake"),
            "hookName": AnyCodable("CI")
        ]
        let fromRow = ConversationMessage(
            id: "m1",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z",
            metadata: meta
        )
        #expect(fromRow.hookWakeAttribution?.displayName == "CI")

        let fromBlock = ConversationMessage(
            id: "m2",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta)],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(fromBlock.hookWakeAttribution?.displayName == "CI")

        let plain = ConversationMessage(
            id: "m3",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(plain.hookWakeAttribution == nil)
    }
}

// MARK: - PR-monitor wake attribution (PROTOCOL §5.42)

struct PrMonitorWakeAttributionTests {
    private func meta(_ extra: [String: AnyCodable] = [:]) -> [String: AnyCodable] {
        var metadata: [String: AnyCodable] = [
            "type": AnyCodable("pr_monitor_wake"),
            "monitorId": AnyCodable("m-1"),
            "repo": AnyCodable("intent-hq/intentd"),
            "prNumber": AnyCodable(512)
        ]
        for (key, value) in extra { metadata[key] = value }
        return metadata
    }

    @Test func extractsFromValidMetadata() {
        let attribution = PrMonitorWakeAttribution.from(meta(["url": AnyCodable("https://example.com/pr")]))
        #expect(attribution == PrMonitorWakeAttribution(
            monitorId: "m-1",
            repo: "intent-hq/intentd",
            prNumber: 512,
            url: "https://example.com/pr"
        ))
    }

    @Test func nilWhenMetadataAbsentMalformedOrWrongType() {
        let message = ConversationMessage(
            id: "m-absent",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(!message.hasReportedMetadata)
        #expect(message.prMonitorWakeAttribution == nil)
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

    @Test func chipLabelFollowsMonitoredPrsRowConvention() throws {
        let attribution = try #require(PrMonitorWakeAttribution.from(meta()))
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
            id: "m1",
            role: .user,
            contentBlocks: [
                ContentBlock(
                    type: .text,
                    text: "x",
                    messageMetadata: meta(["prNumber": AnyCodable(999)])
                )
            ],
            timestamp: "2025-01-01T00:00:00Z",
            metadata: meta()
        )
        #expect(fromRow.prMonitorWakeAttribution?.prNumber == 512)

        let fromBlock = ConversationMessage(
            id: "m2",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta())],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(fromBlock.prMonitorWakeAttribution?.prNumber == 512)

        let plain = ConversationMessage(
            id: "m3",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(plain.prMonitorWakeAttribution == nil)
    }
}
