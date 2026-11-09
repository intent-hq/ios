@testable import Intent
import Testing

// MARK: - Script-monitor wake attribution (FE parity: script-monitor-wake-attribution.ts)

struct ScriptMonitorWakeAttributionTests {
    private func metadata(
        reason: String = "finished",
        overrides: [String: AnyCodable] = [:]
    ) -> [String: AnyCodable] {
        var metadata: [String: AnyCodable] = [
            "type": AnyCodable("script_monitor_wake"),
            "source": AnyCodable("system"),
            "monitorId": AnyCodable("mon-1"),
            "workspaceId": AnyCodable("ws-1"),
            "scriptId": AnyCodable("script-1"),
            "runId": AnyCodable("run-1"),
            "scriptName": AnyCodable("make check"),
            "reason": AnyCodable(reason)
        ]
        metadata.merge(overrides) { _, new in new }
        return metadata
    }

    @Test func extractsFromValidMetadata() {
        #expect(ScriptMonitorWakeAttribution.from(metadata()) == ScriptMonitorWakeAttribution(
            scriptName: "make check",
            scriptId: "script-1",
            runId: "run-1",
            monitorId: "mon-1",
            workspaceId: "ws-1",
            reason: .finished,
            matchedLine: nil
        ))
    }

    @Test func statusLabelFollowsTheReason() {
        let labels = ["finished", "ttl-expired", "output-match", "line-count"].map { reason in
            ScriptMonitorWakeAttribution.from(metadata(reason: reason))?.statusLabel
        }
        #expect(labels == [
            "Run finished; agent notified",
            "Monitoring expired; script left running",
            "Line matched; monitoring ended",
            "Line threshold reached; monitoring ended"
        ])
    }

    @Test func keepsTheMatchedLineOnlyForOutputMatches() {
        let trigger = ["trigger": AnyCodable(["matchedLine": "ERROR: boom"])]
        #expect(ScriptMonitorWakeAttribution.from(
            metadata(reason: "output-match", overrides: trigger)
        )?.matchedLine == "ERROR: boom")
        #expect(ScriptMonitorWakeAttribution.from(
            metadata(reason: "finished", overrides: trigger)
        )?.matchedLine == nil)
    }

    @Test func rejectsUntrustedOrIncompleteMetadata() {
        #expect(ScriptMonitorWakeAttribution.from([:]) == nil)
        #expect(ScriptMonitorWakeAttribution.from(metadata(overrides: ["source": AnyCodable("agent")])) == nil)
        #expect(ScriptMonitorWakeAttribution.from(metadata(overrides: ["type": AnyCodable("hook_wake")])) == nil)
        #expect(ScriptMonitorWakeAttribution.from(metadata(reason: "cancelled")) == nil)
        for key in ["scriptId", "runId", "monitorId", "workspaceId"] {
            #expect(ScriptMonitorWakeAttribution.from(metadata(overrides: [key: AnyCodable("")])) == nil)
        }
        #expect(ScriptMonitorWakeAttribution.from(metadata(overrides: ["scriptName": AnyCodable(7)])) == nil)
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        let fromRow = ConversationMessage(
            id: "m1",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "Script make check finished.")],
            timestamp: "2026-11-09T00:00:00Z",
            metadata: metadata()
        )
        #expect(fromRow.scriptMonitorWakeAttribution?.scriptName == "make check")

        let fromBlock = ConversationMessage(
            id: "m2",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: metadata())],
            timestamp: "2026-11-09T00:00:00Z"
        )
        #expect(fromBlock.scriptMonitorWakeAttribution?.runId == "run-1")

        let plain = ConversationMessage(
            id: "m3",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "Script make check finished.")],
            timestamp: "2026-11-09T00:00:00Z"
        )
        #expect(plain.scriptMonitorWakeAttribution == nil)
    }
}
