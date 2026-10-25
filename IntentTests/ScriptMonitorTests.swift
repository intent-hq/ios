import Foundation
@testable import Intent
import Testing

struct ScriptMonitorTests {
    static var row: [String: Any] {
        [
            "monitorId": "monitor", "workspaceId": "workspace", "agentId": "agent", "scriptId": "script",
            "runId": "run", "scriptName": "Checks 🧪", "mode": "command", "state": "active",
            "createdAt": "2026-10-17T01:00:00Z", "expiresAt": "2026-10-17T02:00:00Z"
        ]
    }

    @Test func summaryPreservesIdentityAndOptionalTriggers() throws {
        var row = Self.row
        let withoutTriggers = try ScriptMonitorSummary(row, workspaceId: "workspace")
        #expect(withoutTriggers.id == "monitor")
        #expect(withoutTriggers.lineCount == nil)
        #expect(withoutTriggers.outputPatternPreview == nil)
        #expect(withoutTriggers.outputPatternTruncated == nil)
        row["lineCount"] = 200
        row["outputPatternPreview"] = "^準備完了 🧪"
        row["outputPatternTruncated"] = true
        row["futureField"] = ["ignored": true]
        let summary = try ScriptMonitorSummary(row, workspaceId: "workspace")
        #expect(summary.outputPatternPreview == "^準備完了 🧪")
        #expect(summary.outputPatternTruncated == true)
        #expect(summary.lineCount == 200)
        #expect(summary != withoutTriggers)
        row["scriptName"] = "Renamed checks"
        #expect(try ScriptMonitorSummary(row, workspaceId: "workspace") != summary)
    }

    @Test func malformedRequiredFieldsAndForeignWorkspaceFailTheWholeRead() {
        for key in ["monitorId", "workspaceId", "agentId", "scriptId", "runId", "scriptName", "mode", "state", "createdAt", "expiresAt"] {
            var row = Self.row
            row.removeValue(forKey: key)
            #expect(throws: ScriptMonitorReadError.self) { try ScriptMonitorSummary(row, workspaceId: "workspace") }
            row[key] = 1
            #expect(throws: ScriptMonitorReadError.self) { try ScriptMonitorSummary(row, workspaceId: "workspace") }
        }
        #expect(throws: ScriptMonitorReadError.self) { try ScriptMonitorSummary(Self.row, workspaceId: "other") }
        for state in ["completed", "triggered", "expired", "cancelled", "future"] {
            var row = Self.row
            row["state"] = state
            #expect(throws: ScriptMonitorReadError.self) { try ScriptMonitorSummary(row, workspaceId: "workspace") }
        }
    }

    @Test func invalidOptionalTriggersAreNotSilentlyDropped() {
        let badFields: [[String: Any]] = [
            ["lineCount": true], ["lineCount": "1"], ["lineCount": 1.5], ["lineCount": 0],
            ["lineCount": 1_000_001], ["lineCount": NSNull()],
            ["outputPatternPreview": "preview"], ["outputPatternTruncated": false],
            ["outputPatternPreview": "preview", "outputPatternTruncated": 1],
            ["outputPatternPreview": String(repeating: "🧪", count: 41), "outputPatternTruncated": true]
        ]
        for fields in badFields {
            let row = Self.row.merging(fields) { _, new in new }
            #expect(throws: ScriptMonitorReadError.self) { try ScriptMonitorSummary(row, workspaceId: "workspace") }
        }
    }

    @Test func detailKeepsFullPatternAndBuildsScalarSafeBoundedPreview() throws {
        var row = Self.row
        let pattern = String(repeating: "🧪", count: 41)
        row["outputPattern"] = pattern
        let detail = try ScriptMonitorDetail(row, workspaceId: "workspace", monitorId: "monitor")
        #expect(detail.outputPattern == pattern)
        #expect(detail.summary.outputPatternPreview == String(repeating: "🧪", count: 40))
        #expect(detail.summary.outputPatternTruncated == true)
        #expect(throws: ScriptMonitorReadError.self) { try ScriptMonitorDetail(row, workspaceId: "workspace", monitorId: "foreign") }
        row["outputPattern"] = NSNull()
        #expect(throws: ScriptMonitorReadError.self) { try ScriptMonitorDetail(row, workspaceId: "workspace", monitorId: "monitor") }
    }

    @Test func invalidTimestampTextRemainsAvailableForPresentationFallback() throws {
        var row = Self.row
        row["expiresAt"] = "not a timestamp"
        #expect(try ScriptMonitorSummary(row, workspaceId: "workspace").expiresAt == "not a timestamp")
    }

    @Test func detailDoesNotMistakeASummaryPreviewForFullConfiguration() {
        var row = Self.row
        row["outputPatternPreview"] = "partial"
        row["outputPatternTruncated"] = true
        #expect(throws: ScriptMonitorReadError.invalidResponse) {
            try ScriptMonitorDetail(row, workspaceId: "workspace", monitorId: "monitor")
        }
    }

    @Test func identityComparisonUsesExactWireBytes() {
        var row = Self.row
        row["workspaceId"] = "café"
        #expect(throws: ScriptMonitorReadError.invalidResponse) {
            try ScriptMonitorSummary(row, workspaceId: "cafe\u{301}")
        }
        row = Self.row
        row["monitorId"] = "café"
        #expect(throws: ScriptMonitorReadError.invalidResponse) {
            try ScriptMonitorDetail(row, workspaceId: "workspace", monitorId: "cafe\u{301}")
        }
    }

    @Test func pageRequiresSummaryDiscriminatorAndValidOpaqueCursor() throws {
        let page = try ScriptMonitorPage(["view": "summary", "monitors": [Self.row], "nextCursor": "opaque:+/="], workspaceId: "workspace")
        #expect(page.monitors.count == 1)
        #expect(page.nextCursor == "opaque:+/=")
        #expect(throws: ScriptMonitorReadError.unsupportedView) { try ScriptMonitorPage(["monitors": []], workspaceId: "workspace") }
        #expect(throws: ScriptMonitorReadError.unsupportedView) {
            try ScriptMonitorPage(["view": "full", "monitors": []], workspaceId: "workspace")
        }
        let invalidCursors: [Any] = ["", NSNull(), 1]
        for invalid in invalidCursors {
            #expect(throws: ScriptMonitorReadError.invalidResponse) {
                try ScriptMonitorPage(["view": "summary", "monitors": [], "nextCursor": invalid], workspaceId: "workspace")
            }
        }
        #expect(throws: ScriptMonitorReadError.invalidResponse) {
            try ScriptMonitorPage(["view": "summary", "monitors": [Self.row, ["monitorId": "broken"]]], workspaceId: "workspace")
        }
        #expect(try ScriptMonitorPage(["view": "summary", "monitors": []], workspaceId: "workspace").monitors.isEmpty)
    }
}
